#!/bin/bash

echo "Running with bash version: $BASH_VERSION"

set -e

INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="$INSTALL_DIR/backup"
CONFIG_FILE="$INSTALL_DIR/config.env"
SCRIPT_NAME="backup_and_notify.sh"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
RETAIN_BACKUPS_DAYS=7
SYMLINK_PATH="/usr/local/bin/rw-backup"

COLOR="\e[1;37m"
RED="\e[31m"
GREEN="\e[32m"
RESET="\e[0m"

print_ascii_art() {
    if command -v toilet &> /dev/null; then
        echo -e "$COLOR"
        toilet -f standard -F metal "remnawave"
        echo -e "$RESET"
    else
        echo "remnawave"
        echo "---------------------------"
    fi
}

install_dependencies() {
    echo "Проверка и установка необходимых пакетов..."
    if [[ $EUID -ne 0 ]]; then
        echo "Этот скрипт требует прав root для установки зависимостей."
        echo "Пожалуйста, запустите его с sudo или от пользователя root."
        exit 1
    fi

    if command -v apt-get &> /dev/null; then
        apt-get update -qq > /dev/null 2>&1 || { echo "Ошибка при обновлении списка пакетов."; exit 1; }
        apt-get install -y toilet curl docker.io gzip > /dev/null 2>&1 || { echo "Ошибка при установке необходимых пакетов."; exit 1; }
        echo "Необходимые пакеты установлены или уже присутствуют."
    else
        echo "Не удалось найти apt-get. Пожалуйста, установите toilet, curl, docker.io и gzip вручную."
        command -v curl &> /dev/null || { echo "curl не найден. Установите его."; exit 1; }
        command -v docker &> /dev/null || { echo "docker не найден. Установите его."; exit 1; }
        command -v gzip &> /dev/null || { echo "gzip не найден. Установите его."; exit 1; }
        echo "Необходимые пакеты (кроме toilet) найдены."
    fi
}

load_or_create_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Загрузка конфигурации из $CONFIG_FILE..."
        source "$CONFIG_FILE"
        if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || -z "$DB_USER" ]]; then
            echo "В файле конфигурации отсутствуют необходимые переменные (BOT_TOKEN, CHAT_ID, DB_USER)."
            echo "Пожалуйста, удалите $CONFIG_FILE и запустите скрипт снова для создания новой конфигурации."
            exit 1
        fi
    else
        echo "=== Конфигурация не найдена, создаем новую ==="
        read -rp "Введите Telegram Bot Token: " BOT_TOKEN
        read -rp "Введите Telegram Chat ID: " CHAT_ID
        read -rp "Введите имя пользователя PostgreSQL (по умолчанию postgres): " DB_USER
        DB_USER=${DB_USER:-postgres}

        mkdir -p "$INSTALL_DIR" || { echo "Ошибка при создании каталога $INSTALL_DIR."; exit 1; }
        mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога $BACKUP_DIR."; exit 1; }

        cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
EOF

        chmod 600 "$CONFIG_FILE" || { echo "Ошибка при установке прав доступа для $CONFIG_FILE."; exit 1; }
        echo "Конфигурация сохранена в $CONFIG_FILE"
    fi
}

escape_markdown_v2() {
    local text="$1"
    echo "$text" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/_/\\_/g' \
        -e 's/\[/\\[/g' \
        -e 's/\]/\\]/g' \
        -e 's/(/\\(/g' \
        -e 's/)/\\)/g' \
        -e 's/~/\~/g' \
        -e 's/`/\\`/g' \
        -e 's/>/\\>/g' \
        -e 's/#/\\#/g' \
        -e 's/+/\\+/g' \
        -e 's/-/\\-/g' \
        -e 's/=/\\=/g' \
        -e 's/|/\\|/g' \
        -e 's/{/\\{/g' \
        -e 's/}/\\}/g' \
        -e 's/\./\\./g' \
        -e 's/!/\!/g'
}

send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-MarkdownV2}"
    local escaped_message
    escaped_message=$(escape_markdown_v2 "$message")

    local http_code=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$escaped_message" \
        -d parse_mode="$parse_mode" \
        -w "%{http_code}" -o /dev/null 2>&1)

    if [[ "$http_code" -eq 200 ]]; then
        return 0
    else
        echo "Ошибка отправки сообщения в Telegram. HTTP код: $http_code"
        return 1
    fi
}

send_telegram_document() {
    local file_path="$1"
    local caption="$2"
    local parse_mode="MarkdownV2"
    local escaped_caption
    escaped_caption=$(escape_markdown_v2 "$caption")

    local api_response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        -F chat_id="$CHAT_ID" \
        -F document=@"$file_path" \
        -F parse_mode="$parse_mode" \
        -F caption="$escaped_caption" \
        -w "%{http_code}" -o /dev/null 2>&1)

    local curl_status=$?

    if [ $curl_status -ne 0 ]; then
        echo "❌ Ошибка CURL при отправке документа в Telegram. Код выхода: $curl_status"
        return 1
    fi

    local http_code="${api_response: -3}"

    if [[ "$http_code" -eq 200 ]]; then
        return 0
    else
        echo "❌ Telegram API вернул ошибку HTTP. Код: $http_code"
        return 1
    fi
}


create_backup() {
    echo "💾 Запись резервной копии..."

    mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога бэкапов $BACKUP_DIR."; send_telegram_message "❌ Ошибка: Не удалось создать каталог бэкапов $BACKUP_DIR." "None"; exit 1; }

    DATE=$(date +'%Y-%m-%d %H:%M:%S')
    TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S')
    FILENAME="remnawave-db-${TIMESTAMP}.sql.gz"
    FULL_PATH="$BACKUP_DIR/$FILENAME"

    if ! docker inspect remnawave-db > /dev/null 2>&1 || ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        echo "Ошибка: Контейнер 'remnawave-db' не найден или не запущен."
        send_telegram_message "❌ Ошибка: Контейнер 'remnawave-db' не найден или не запущен. Не удалось создать бэкап." "None"; exit 1
    fi
    
    if ! docker exec -i remnawave-db pg_dumpall -c -U "$DB_USER" | gzip -9 > "$FULL_PATH"; then
        STATUS=$?
        echo "❌ Ошибка при создании бэкапа. Код выхода: $STATUS"
        send_telegram_message "❌ Ошибка при создании бэкапа Remnawave DB. Код выхода: ${STATUS}" "None"; exit $STATUS
    fi

    echo -e "✅ Бэкап успешно создан и находится по пути:\n $FULL_PATH"

    echo -e "Применение политики хранения бэкапов\n(оставляем за последние $RETAIN_BACKUPS_DAYS дней)..."
    find "$BACKUP_DIR" -maxdepth 1 -name "remnawave-db-*.sql.gz" -mtime +$RETAIN_BACKUPS_DAYS -delete

    echo "Отправка бэкапа в Telegram..."
    local caption_text=$'💾#backup_success\n➖➖➖➖➖➖➖➖➖\n✅ *The backup has been created*\n📅Date: '"${DATE}"

    if [[ -f "$FULL_PATH" ]]; then
        if send_telegram_document "$FULL_PATH" "$caption_text"; then
            echo "✅ Успешно"
        else
            echo "❌ Ошибка при отправке бэкапа в Telegram. Подробности выше."
        fi
    else
        echo "❌ Ошибка: Файл бэкапа не найден после создания: $FULL_PATH"
        send_telegram_message "❌ Ошибка: Файл бэкапа не найден после создания: ${FILENAME}" "None"; exit 1
    fi
}

setup_auto_send() {
    while true; do
        echo ""
        echo "=== Настройка автоматической отправки ==="
        echo "1) Включить"
        echo "2) Выключить"
        echo "3) Вернуться назад"
        read -rp "Выберите пункт: " choice
        case $choice in
            1)
                read -rp "Введите время отправки (например, 03:00 15:00 ): " times
                valid_times=()
                invalid_format=false
                IFS=' ' read -ra arr <<< "$times"
                for t in "${arr[@]}"; do
                    if [[ $t =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                        hour=${BASH_REMATCH[1]}
                        min=${BASH_REMATCH[2]}
                        if (( 10#$hour >= 0 && 10#$hour <= 23 && 10#$min >= 0 && 10#$min <= 59 )); then
                            valid_times+=("$min $hour")
                        else
                            echo "Неверное значение времени: $t (часы 0-23, минуты 0-59)"
                            invalid_format=true
                            break
                        fi
                    else
                        echo "Неверный формат времени: $t (ожидается HH:MM)"
                        invalid_format=true
                        break
                    fi
                done

                if [ "$invalid_format" = true ] || [ ${#valid_times[@]} -eq 0 ]; then
                    echo "Автоматическая отправка не настроена из-за ошибок ввода времени."
                    continue
                fi

                echo "⏳ Настройка времени..."
                (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH") | crontab -

                for time_entry in "${valid_times[@]}"; do
                    (crontab -l 2>/dev/null; echo "$time_entry * * * $SCRIPT_PATH backup") | crontab -
                done

                sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                echo "CRON_TIMES=\"$times\"" >> "$CONFIG_FILE"
                echo "✅ Автоматическая отправка установлена на: $times"
                ;;
            2)
                echo "Отключение автоматической отправки..."
                crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
                sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                echo "Автоматическая отправка отключена."
                ;;
            3) break ;;
            *) echo "Неверный ввод." ;;
        esac
        read -rp "Нажмите Enter для продолжения..."
    done
}

restore_backup() {
    echo -e ""
    echo -e "=== Восстановление из бэкапа ==="
    echo -e "${RED}!!! ВНИМАНИЕ: Восстановление полностью перезапишет базу данных Remnawave !!!${RESET}"
    echo -e "Поместите файл бэкапа (*.sql.gz) в папку: $BACKUP_DIR"
    echo -e "Убедитесь, что выбрали правильный файл бэкапа"
    echo -e ""

    echo "Доступные файлы бэкапов в $BACKUP_DIR:"
    BACKUP_FILES=("$BACKUP_DIR"/remnawave-db-*.sql.gz)
    if [ ${#BACKUP_FILES[@]} -eq 0 ] || [ ! -f "${BACKUP_FILES[0]}" ]; then
        echo "Не найдено файлов бэкапов в $BACKUP_DIR."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    readarray -t SORTED_BACKUP_FILES < <(ls -t "$BACKUP_DIR"/remnawave-db-*.sql.gz 2>/dev/null)

    echo "Выберите файл для восстановления:"
    select SELECTED_BACKUP in "${SORTED_BACKUP_FILES[@]}"; do
        if [[ -n "$SELECTED_BACKUP" ]]; then
            echo "Выбран файл: $SELECTED_BACKUP"
            break
        else
            echo "Неверный выбор."
        fi
    done

    echo -e $'Вы уверены, что хотите восстановить базу данных?\nВведите '"${GREEN}Y${RESET}"$' для подтверждения: '
    read -r confirm_restore

    if [[ "${confirm_restore,,}" != "y" ]]; then
        echo "Восстановление отменено."
        return
    fi

    echo "Подготовка системы к восстановлению..."

    echo "Остановка сервисов Remnawave..."
    if ! cd /opt/remnawave; then
        echo "Ошибка: Не удалось перейти в каталог /opt/remnawave. Убедитесь, что файл docker-compose.yml находится там."
        local error_msg="❌ Ошибка при восстановлении: Не удалось найти каталог /opt/remnawave."
        local escaped_error_msg=$(escape_markdown_v2 "$error_msg")
        send_telegram_message "$escaped_error_msg" "MarkdownV2"; return
    fi

    if ! docker compose stop; then
           echo "Предупреждение: Не удалось остановить все сервисы docker compose. Продолжаем, но могут быть проблемы с подключением к БД."
           local warning_msg="⚠️ Предупреждение: Не удалось остановить все сервисы docker compose. Продолжаем, но могут быть проблемы с подключением к БД."
           local escaped_warning_msg=$(escape_markdown_v2 "$warning_msg")
           send_telegram_message "$escaped_warning_msg" "MarkdownV2"
    fi

      if ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        local error_prefix="❌ Ошибка при восстановлении: Контейнер 'remnawave-db' не запущен."
        local escaped_error_prefix=$(escape_markdown_v2 "$error_prefix")
        #send_telegram_message "$escaped_error_prefix" "MarkdownV2"

        echo "Запуск remnawave-db..."
        if ! docker compose up -d remnawave-db; then
            echo "Критическая ошибка: Не удалось запустить контейнер 'remnawave-db'. Восстановление невозможно."
            local critical_error_prefix="❌ Критическая ошибка при восстановлении: Не удалось запустить контейнер 'remnawave-db'."
            local escaped_critical_error_prefix=$(escape_markdown_v2 "$critical_error_prefix")
            send_telegram_message "$escaped_critical_error_prefix" "MarkdownV2"; return
        fi
        sleep 5
          if ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
              echo "Критическая ошибка: Контейнер 'remnawave-db' все еще не запущен после попытки старта. Восстановление невозможно."
              local critical_error_prefix_2="❌ Критическая ошибка при восстановлении: Контейнер 'remnawave-db' не запущен после попытки старта."
              local escaped_critical_error_prefix_2=$(escape_markdown_v2 "$critical_error_prefix_2")
              send_telegram_message "$escaped_critical_error_prefix_2" "MarkdownV2"; return
          fi
    fi

      if ! docker exec -i remnawave-db psql -U "$DB_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
          echo "Ошибка: Не удалось подключиться к базе данных 'postgres' в контейнере 'remnawave-db' с пользователем '$DB_USER'."
          echo "Проверьте имя пользователя БД в $CONFIG_FILE и доступность контейнера."
          local db_connect_error_prefix="❌ Ошибка при восстановлении: Не удалось подключиться к БД в контейнере 'remnawave-db'."
          local escaped_db_connect_error_prefix=$(escape_markdown_v2 "$db_connect_error_prefix")
          send_telegram_message "$escaped_db_connect_error_prefix" "MarkdownV2"; return
      fi

    echo "🔄 Начало процесса восстановления..."
    if gunzip -c "$SELECTED_BACKUP" | docker exec -i remnawave-db psql -U "$DB_USER" -d postgres > /dev/null 2>&1; then
        echo "✅ Восстановление успешно завершено."
        # Escape prefix, keep filename raw
        local restore_success_prefix="✅ Восстановление Remnawave DB успешно завершено из файла: "
        local restored_filename="${SELECTED_BACKUP##*/}"
        local escaped_restore_success_prefix=$(escape_markdown_v2 "$restore_success_prefix")
        local final_restore_success_message="${escaped_restore_success_prefix}${restored_filename}"
        send_telegram_message "$final_restore_success_message" "MarkdownV2"

    else
        STATUS=$?
        echo "❌ Ошибка при выполнении восстановления. Код выхода: $STATUS"
        local restore_error_prefix="❌ Ошибка при выполнении восстановления Remnawave DB из файла: "
        local restored_filename_error="${SELECTED_BACKUP##*/}"
        local error_suffix=". Код выхода: ${STATUS}"
        local escaped_restore_error_prefix=$(escape_markdown_v2 "$restore_error_prefix")
        local escaped_error_suffix=$(escape_markdown_v2 "$error_suffix")
        local final_restore_error_message="${escaped_restore_error_prefix}${restored_filename_error}${escaped_error_suffix}"
        send_telegram_message "$final_restore_error_message" "MarkdownV2"
    fi

    echo "Перезапуск всех сервисов Remnawave..."
    if ! docker compose up -d; then
        echo "Ошибка: Не удалось запустить все сервисы docker compose после восстановления."
        local docker_compose_error_prefix="❌ Ошибка: Не удалось запустить все сервисы docker compose после восстановления."
        local escaped_docker_compose_error_prefix=$(escape_markdown_v2 "$docker_compose_error_prefix")
        send_telegram_message "$escaped_docker_compose_error_prefix" "MarkdownV2"
    else
        echo "✅ Все сервисы Remnawave запущены."
    fi

}


setup_symlink() {
    echo ""
    echo "=== Настройка команды быстрого доступа ==="
    if [[ -L "$SYMLINK_PATH" && -e "$SYMLINK_PATH" ]]; then
        echo "Команда быстрого доступа уже активирована"
    elif [[ -e "$SYMLINK_PATH" && ! -L "$SYMLINK_PATH" ]]; then
          echo "Ошибка: Файл или каталог с именем '$SYMLINK_PATH' уже существует, но не является символической ссылкой."
          echo "Пожалуйста, удалите его вручную, если хотите создать ссылку."
    else
        echo "Создание команды быстрого доступа..."
        if [[ -d "/usr/local/bin" && -w "/usr/local/bin" ]]; then
            if ln -s "$SCRIPT_PATH" "$SYMLINK_PATH"; then
                echo -e "✅ Готово.Для доступа к скрипту пользуйтесь командой \e[1mrw-backup${RESET}"
            else
                echo "❌ Ошибка при создании символической ссылки командой ln -s. Проверьте права доступа."
            fi
        else
            echo "❌ Ошибка: Каталог /usr/local/bin не найден или недоступен для записи пользователем root."
            echo "Создание символической ссылки невозможно."
        fi
    fi
    read -rp "Нажмите Enter для продолжения..."
}

if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт требует прав root для установки, настройки cron и создания символической ссылки."
    echo "Пожалуйста, запустите его с sudo или от пользователя root."
    exit 1
fi

mkdir -p "$INSTALL_DIR" || { echo "Ошибка при создании каталога $INSTALL_DIR."; exit 1; }
mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога $BACKUP_DIR."; exit 1; }


install_dependencies

load_or_create_config

if [[ "$1" == "backup" ]]; then
    echo "Запуск бэкапа по расписанию..."
    create_backup
    exit 0
fi

main_menu() {
    while true; do
        clear
        print_ascii_art
        echo "=== Главное меню ==="
        echo "1) Сделать бэкап вручную"
        echo "2) Настройка автоматической отправки и уведомлений"
        echo "3) Восстановление из бэкапа"
        echo "4) Активировать быстрый доступ к скрипту"
        echo "5) Выход"
        read -rp "Выберите пункт: " choice
        case $choice in
            1) create_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            2) setup_auto_send ;;
            3) restore_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            4) setup_symlink ; read -rp "Нажмите Enter для продолжения..." ;;
            5) echo "Выход..."; exit 0 ;;
            *) echo "Неверный ввод." ; read -rp "Нажмите Enter для продолжения..." ;;
        esac
    done
}

echo "Starting main menu..."
main_menu
