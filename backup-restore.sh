#!/bin/bash

set -e

INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="$INSTALL_DIR/backup"
CONFIG_FILE="$INSTALL_DIR/config.env"
SCRIPT_NAME="backup-restore.sh"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
RETAIN_BACKUPS_DAYS=7
SYMLINK_PATH="/usr/local/bin/rw-backup"
REMNALABS_ROOT_DIR="/opt/remnawave"
ENV_NODE_FILE=".env-node"
ENV_FILE=".env"
SCRIPT_REPO_URL="https://raw.githubusercontent.com/distillium/test/main/backup-restore.sh"
SCRIPT_RUN_PATH="$(realpath "$0")"

if [[ -t 0 ]]; then
    RED="\e[31m"
    GREEN="\e[32m"
    YELLOW="\e[33m"
    GRAY="\e[37m"
    CYAN="\e[36m"
    RESET="\e[0m"
    BOLD="\e[1m"
    USE_ASCII_ART=true
else
    RED=""
    GREEN=""
    YELLOW=""
    GRAY=""
    CYAN=""
    RESET=""
    BOLD=""
    USE_ASCII_ART=false
fi

print_ascii_art() {
    if $USE_ASCII_ART && command -v toilet &> /dev/null; then
        echo -e "\e[1;37m"
        toilet -f standard -F metal "remnawave"
        echo -e "\e[0m"
    elif $USE_ASCII_ART; then
        echo "remnawave"
    fi
}

print_message() {
    local type="$1"
    local message="$2"
    local color_code="$RESET"

    case "$type" in
        "INFO") color_code="$GRAY" ;;
        "SUCCESS") color_code="$GREEN" ;;
        "WARN") color_code="$YELLOW" ;;
        "ERROR") color_code="$RED" ;;
        "ACTION") color_code="$CYAN" ;;
        *) type="INFO" ;;
    esac

    echo -e "${color_code}[$type]${RESET} $message"
}

setup_symlink() {
    echo ""
    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "Для управления символической ссылкой ${BOLD}${SYMLINK_PATH}${RESET} требуются права root. Пропускаем настройку."
        return 1
    fi

    if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
        print_message "SUCCESS" "Символическая ссылка ${BOLD}${SYMLINK_PATH}${RESET} уже настроена и указывает на ${BOLD}${SCRIPT_PATH}${RESET}."
        return 0
    fi

    print_message "INFO" "Создание или обновление символической ссылки ${BOLD}${SYMLINK_PATH}${RESET}..."
    rm -f "$SYMLINK_PATH"
    if [[ -d "$(dirname "$SYMLINK_PATH")" ]]; then
        if ln -s "$SCRIPT_PATH" "$SYMLINK_PATH"; then
            print_message "SUCCESS" "Символическая ссылка ${BOLD}${SYMLINK_PATH}${RESET} успешно настроена."
        else
            print_message "ERROR" "Не удалось создать символическую ссылку ${BOLD}${SYMLINK_PATH}${RESET}. Проверьте права доступа."
            return 1
        fi
    else
        print_message "ERROR" "Каталог ${BOLD}$(dirname "$SYMLINK_PATH")${RESET} не найден. Символическая ссылка не создана."
        return 1
    fi
    echo ""
    return 0
}

install_dependencies() {
    print_message "INFO" "Проверка и установка необходимых пакетов..."
    echo ""

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Ошибка: Этот скрипт требует прав root для установки зависимостей. Пожалуйста, запустите его с '${BOLD}sudo${RESET}' или от пользователя '${BOLD}root${RESET}'.${RESET}"
        exit 1
    fi

    if command -v apt-get &> /dev/null; then
        print_message "INFO" "Обновление списка пакетов ${BOLD}apt${RESET}..."
        apt-get update -qq > /dev/null 2>&1 || { echo -e "${RED}❌ Ошибка: Не удалось обновить список пакетов ${BOLD}apt${RESET}. Проверьте подключение к интернету.${RESET}"; exit 1; }
        apt-get install -y toilet figlet procps lsb-release whiptail curl gzip > /dev/null 2>&1 || { echo -e "${RED}❌ Ошибка: Не удалось установить необходимые пакеты. Проверьте ошибки установки.${RESET}"; exit 1; }
        print_message "SUCCESS" "Все необходимые пакеты установлены или уже присутствуют в системе."
    else
        print_message "WARN" "Внимание: Не удалось найти менеджер пакетов ${BOLD}'apt-get'${RESET}. Установка зависимостей может потребоваться вручную."
        command -v curl &> /dev/null || { echo -e "${RED}❌ Ошибка: ${BOLD}'curl'${RESET} не найден. Установите его вручную.${RESET}"; exit 1; }
        command -v docker &> /dev/null || { echo -e "${RED}❌ Ошибка: ${BOLD}'docker'${RESET} не найден. Установите его вручную.${RESET}"; exit 1; }
        command -v gzip &> /dev/null || { echo -e "${RED}❌ Ошибка: ${BOLD}'gzip'${RESET} не найден. Установите его вручную.${RESET}"; exit 1; }
        print_message "SUCCESS" "Основные зависимости (${BOLD}curl${RESET}, ${BOLD}docker${RESET}, ${BOLD}gzip${RESET}) найдены."
    fi
    echo ""
}

load_or_create_config() {
    if $USE_ASCII_ART; then clear; fi
    print_ascii_art

    if [[ -f "$CONFIG_FILE" ]]; then
        print_message "INFO" "Загрузка конфигурации..."
        source "$CONFIG_FILE"
        echo ""

        if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || -z "$DB_USER" ]]; then
            print_message "WARN" "В файле конфигурации отсутствуют необходимые переменные."
            print_message "ACTION" "Пожалуйста, введите недостающие данные:"
            echo ""

            [[ -z "$BOT_TOKEN" ]] && read -rp "   Введите Telegram Bot Token: " BOT_TOKEN
            [[ -z "$CHAT_ID" ]] && read -rp "   Введите Telegram Chat ID: " CHAT_ID
            [[ -z "$DB_USER" ]] && read -rp "   Введите имя пользователя PostgreSQL (по умолчанию postgres): " DB_USER
            DB_USER=${DB_USER:-postgres}
            echo ""

            cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
EOF

            chmod 600 "$CONFIG_FILE" || { print_message "ERROR" "Не удалось установить права доступа (600) для ${BOLD}${CONFIG_FILE}${RESET}. Проверьте разрешения."; exit 1; }
            print_message "SUCCESS" "Конфигурация дополнена и сохранена в ${BOLD}${CONFIG_FILE}${RESET}"
        else
            print_message "SUCCESS" "Конфигурация успешно загружена из ${BOLD}${CONFIG_FILE}${RESET}."
        fi
    else
        if [[ "$SCRIPT_RUN_PATH" != "$SCRIPT_PATH" ]]; then
            print_message "INFO" "Конфигурация не найдена. Скрипт запущен из временного расположения."
            print_message "INFO" "Перемещаем скрипт в основной каталог установки: ${BOLD}${SCRIPT_PATH}${RESET}..."
            mkdir -p "$INSTALL_DIR" || { print_message "ERROR" "Не удалось создать каталог установки ${BOLD}${INSTALL_DIR}${RESET}. Проверьте права доступа."; exit 1; }
            mkdir -p "$BACKUP_DIR" || { print_message "ERROR" "Не удалось создать каталог для бэкапов ${BOLD}${BACKUP_DIR}${RESET}. Проверьте права доступа."; exit 1; }

            if mv "$SCRIPT_RUN_PATH" "$SCRIPT_PATH"; then
                chmod +x "$SCRIPT_PATH"
                print_message "SUCCESS" "Скрипт успешно перемещен в ${BOLD}${SCRIPT_PATH}${RESET}."
                echo ""
                print_message "ACTION" "Перезапускаем скрипт из нового расположения для завершения настройки..."
                exec "$SCRIPT_PATH" "$@"
                exit 0
            else
                print_message "ERROR" "Не удалось переместить скрипт в ${BOLD}${SCRIPT_PATH}${RESET}. Проверьте права доступа."
                exit 1
            fi
        else
            print_message "INFO" "Конфигурация не найдена, создаем новую..."
            echo ""
            read -rp "   Введите Telegram Bot Token: " BOT_TOKEN
            read -rp "   Введите Telegram Chat ID: " CHAT_ID
            read -rp "   Введите имя пользователя PostgreSQL (по умолчанию postgres): " DB_USER
            DB_USER=${DB_USER:-postgres}
            echo ""

            mkdir -p "$INSTALL_DIR" || { print_message "ERROR" "Не удалось создать каталог установки ${BOLD}${INSTALL_DIR}${RESET}. Проверьте права доступа."; exit 1; }
            mkdir -p "$BACKUP_DIR" || { print_message "ERROR" "Не удалось создать каталог для бэкапов ${BOLD}${BACKUP_DIR}${RESET}. Проверьте права доступа."; exit 1; }

            cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
EOF

            chmod 600 "$CONFIG_FILE" || { print_message "ERROR" "Не удалось установить права доступа (600) для ${BOLD}${CONFIG_FILE}${RESET}. Проверьте разрешения."; exit 1; }
            print_message "SUCCESS" "Новая конфигурация сохранена в ${BOLD}${CONFIG_FILE}${RESET}"
        fi
    fi
    echo ""
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
        echo -e "${RED}❌ Ошибка отправки сообщения в Telegram. HTTP код: ${BOLD}$http_code${RESET}. Убедитесь, что ${BOLD}BOT_TOKEN${RESET} и ${BOLD}CHAT_ID${RESET} верны.${RESET}"
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
        echo -e "${RED}❌ Ошибка ${BOLD}CURL${RESET} при отправке документа в Telegram. Код выхода: ${BOLD}$curl_status${RESET}. Проверьте сетевое соединение.${RESET}"
        return 1
    fi

    local http_code="${api_response: -3}"

    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        echo -e "${RED}❌ Telegram API вернул ошибку HTTP. Код: ${BOLD}$http_code${RESET}. Ответ: ${BOLD}$api_response${RESET}. Возможно, файл слишком большой или ${BOLD}BOT_TOKEN${RESET}/${BOLD}CHAT_ID${RESET} неверны.${RESET}"
        return 1
    fi
}

create_backup() {
    print_message "INFO" "Начинаю процесс создания резервной копии..."
    echo ""

    TIMESTAMP=$(date +%Y-%m-%d"_"%H_%M_%S)
    BACKUP_FILE_DB="dump_${TIMESTAMP}.sql.gz"
    BACKUP_FILE_FINAL="remnawave_backup_${TIMESTAMP}.tar.gz"
    ENV_NODE_PATH="$REMNALABS_ROOT_DIR/$ENV_NODE_FILE"
    ENV_PATH="$REMNALABS_ROOT_DIR/$ENV_FILE"

    mkdir -p "$BACKUP_DIR" || { echo -e "${RED}❌ Ошибка: Не удалось создать каталог для бэкапов. Проверьте права доступа.${RESET}"; send_telegram_message "❌ Ошибка: Не удалось создать каталог бэкапов ${BOLD}$BACKUP_DIR${RESET}." "None"; exit 1; }

    if ! docker inspect remnawave-db > /dev/null 2>&1 || ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        echo -e "${RED}❌ Ошибка: Контейнер ${BOLD}'remnawave-db'${RESET} не найден или не запущен. Невозможно создать бэкап базы данных.${RESET}"
        send_telegram_message "❌ Ошибка: Контейнер ${BOLD}'remnawave-db'${RESET} не найден или не запущен. Не удалось создать бэкап." "None"; exit 1
    fi
    print_message "INFO" "Создание PostgreSQL дампа и сжатие в файл..."
    if ! docker exec -t "remnawave-db" pg_dumpall -c -U "$DB_USER" | gzip -9 > "$BACKUP_DIR/$BACKUP_FILE_DB"; then
        STATUS=$?
        echo -e "${RED}❌ Ошибка при создании дампа PostgreSQL. Код выхода: ${BOLD}$STATUS${RESET}. Проверьте имя пользователя БД и доступ к контейнеру.${RESET}"
        send_telegram_message "❌ Ошибка при создании дампа PostgreSQL. Код выхода: ${BOLD}${STATUS}${RESET}" "None"; exit $STATUS
    fi
    print_message "SUCCESS" "Дамп PostgreSQL успешно создан."
    echo ""
    print_message "INFO" "Архивирование бэкапа в файл..."
    
    FILES_TO_ARCHIVE=("$BACKUP_FILE_DB")
    
    if [ -f "$ENV_NODE_PATH" ]; then
        print_message "INFO" "Обнаружен файл ${BOLD}${ENV_NODE_FILE}${RESET}. Добавляем его в архив."
        cp "$ENV_NODE_PATH" "$BACKUP_DIR/" || { echo -e "${RED}❌ Ошибка при копировании ${BOLD}${ENV_NODE_FILE}${RESET} для бэкапа.${RESET}"; send_telegram_message "❌ Ошибка: Не удалось скопировать ${BOLD}${ENV_NODE_FILE}${RESET} для бэкапа." "None"; exit 1; }
        FILES_TO_ARCHIVE+=("$ENV_NODE_FILE")
    else
        print_message "WARN" "Файл ${BOLD}${ENV_NODE_FILE}${RESET} не найден. Продолжаем без него."
    fi

    if [ -f "$ENV_PATH" ]; then
        print_message "INFO" "Обнаружен файл ${BOLD}${ENV_FILE}${RESET}. Добавляем его в архив."
        cp "$ENV_PATH" "$BACKUP_DIR/" || { echo -e "${RED}❌ Ошибка при копировании ${BOLD}${ENV_FILE}${RESET} для бэкапа.${RESET}"; send_telegram_message "❌ Ошибка: Не удалось скопировать ${BOLD}${ENV_FILE}${RESET} для бэкапа." "None"; exit 1; }
        FILES_TO_ARCHIVE+=("$ENV_FILE")
    else
        print_message "WARN" "Файл ${BOLD}${ENV_FILE}${RESET} не найден по пути. Продолжаем без него."
    fi
    echo ""

    if ! tar -czf "$BACKUP_DIR/$BACKUP_FILE_FINAL" -C "$BACKUP_DIR" "${FILES_TO_ARCHIVE[@]}"; then
        STATUS=$?
        echo -e "${RED}❌ Ошибка при архивировании бэкапа. Код выхода: ${BOLD}$STATUS${RESET}. Проверьте наличие свободного места и права доступа.${RESET}"
        send_telegram_message "❌ Ошибка при архивировании бэкапа. Код выхода: ${BOLD}${STATUS}${RESET}" "None"; exit $STATUS
    fi
    print_message "SUCCESS" "Архив бэкапа успешно создан: ${BOLD}${BACKUP_DIR}/${BACKUP_FILE_FINAL}${RESET}"
    echo ""

    print_message "INFO" "Очистка промежуточных файлов бэкапа..."
    rm -f "$BACKUP_DIR/$BACKUP_FILE_DB"
    rm -f "$BACKUP_DIR/$ENV_NODE_FILE"
    rm -f "$BACKUP_DIR/$ENV_FILE"
    print_message "SUCCESS" "Промежуточные файлы удалены."
    echo ""

    print_message "INFO" "Применение политики хранения бэкапов (оставляем за последние ${BOLD}${RETAIN_BACKUPS_DAYS}${RESET} дней)..."
    find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -mtime +$RETAIN_BACKUPS_DAYS -delete
    print_message "SUCCESS" "Политика хранения применена. Старые бэкапы удалены."
    echo ""

    print_message "INFO" "Отправка бэкапа в Telegram..."
    local DATE=$(date +'%Y-%m-%d %H:%M:%S')
    local caption_text=$'💾#backup_success\n➖➖➖➖➖➖➖➖➖\n✅ *Бэкап успешно создан*\n📅Дата: '"${DATE}"

    if [[ -f "$BACKUP_DIR/$BACKUP_FILE_FINAL" ]]; then
        if send_telegram_document "$BACKUP_DIR/$BACKUP_FILE_FINAL" "$caption_text"; then
            print_message "SUCCESS" "Бэкап успешно отправлен в Telegram."
        else
            echo -e "${RED}❌ Ошибка при отправке бэкапа в Telegram. Проверьте настройки Telegram API (токен, ID чата).${RESET}"
        fi
    else
        echo -e "${RED}❌ Ошибка: Финальный файл бэкапа не найден после создания: ${BOLD}${BACKUP_DIR}/${BACKUP_FILE_FINAL}${RESET}. Отправка невозможна.${RESET}"
        send_telegram_message "❌ Ошибка: Файл бэкапа не найден после создания: ${BOLD}${BACKUP_FILE_FINAL}${RESET}" "None"; exit 1
    fi
    echo ""
}

setup_auto_send() {
    echo ""
    if [[ $EUID -ne 0 ]]; then
        print_message "WARN" "Для настройки cron требуются права root. Пожалуйста, запустите с '${BOLD}sudo'${RESET}.${RESET}"
        read -rp "Нажмите Enter для продолжения..."
        return
    fi
    while true; do
        clear
        print_ascii_art
        echo "=== Настройка автоматической отправки ==="
        echo "   1) Включить автоматическую отправку бэкапов"
        echo "   2) Выключить автоматическую отправку бэкапов"
        echo "   0) Вернуться в главное меню"
        echo ""
        read -rp "Выберите пункт: " choice
        echo ""
        case $choice in
            1)
                read -rp "Введите время отправки (например, 03:00 15:00): " times
                valid_times_cron=()
                user_friendly_times=""
                invalid_format=false
                IFS=' ' read -ra arr <<< "$times"
                for t in "${arr[@]}"; do
                    if [[ $t =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                        hour=${BASH_REMATCH[1]}
                        min=${BASH_REMATCH[2]}
                        hour_val=$((10#$hour))
                        min_val=$((10#$min))
                        if (( hour_val >= 0 && hour_val <= 23 && min_val >= 0 && min_val <= 59 )); then
                            valid_times_cron+=("$min_val $hour_val")
                            user_friendly_times+="$t "
                        else
                            print_message "ERROR" "Неверное значение времени: ${BOLD}$t${RESET} (часы 0-23, минуты 0-59)."
                            invalid_format=true
                            break
                        fi
                    else
                        print_message "ERROR" "Неверный формат времени: ${BOLD}$t${RESET} (ожидается HH:MM)."
                        invalid_format=true
                        break
                    fi
                done
                echo ""

                if [ "$invalid_format" = true ] || [ ${#valid_times_cron[@]} -eq 0 ]; then
                    print_message "ERROR" "Автоматическая отправка не настроена из-за ошибок ввода времени. Пожалуйста, попробуйте еще раз."
                    continue
                fi

                print_message "INFO" "Настройка cron-задачи для автоматической отправки..."
                
                local temp_crontab_file=$(mktemp)

                crontab -l 2>/dev/null > "$temp_crontab_file"

                if ! grep -q "^SHELL=" "$temp_crontab_file"; then
                    echo "SHELL=/bin/bash" | cat - "$temp_crontab_file" > "$temp_crontab_file.tmp"
                    mv "$temp_crontab_file.tmp" "$temp_crontab_file"
                    print_message "INFO" "SHELL=/bin/bash добавлен в crontab."
                fi

                if ! grep -q "^PATH=" "$temp_crontab_file"; then
                    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" | cat - "$temp_crontab_file" > "$temp_crontab_file.tmp"
                    mv "$temp_crontab_file.tmp" "$temp_crontab_file"
                    print_message "INFO" "PATH переменная добавлена в crontab."
                else
                    print_message "INFO" "PATH переменная уже существует в crontab."
                fi

                grep -vF "$SCRIPT_PATH backup" "$temp_crontab_file" > "$temp_crontab_file.tmp"
                mv "$temp_crontab_file.tmp" "$temp_crontab_file"

                for time_entry in "${valid_times_cron[@]}"; do
                    echo "$time_entry * * * $SCRIPT_PATH backup >> /var/log/rw_backup_cron.log 2>&1" >> "$temp_crontab_file"
                done
                
                if crontab "$temp_crontab_file"; then
                    print_message "SUCCESS" "CRON-задача для автоматической отправки успешно установлена."
                else
                    print_message "ERROR" "Не удалось установить CRON-задачу. Проверьте права доступа и наличие crontab."
                fi

                rm -f "$temp_crontab_file"

                if grep -q "^CRON_TIMES=" "$CONFIG_FILE"; then
                    sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                fi
                echo "CRON_TIMES=\"${user_friendly_times% }\"" >> "$CONFIG_FILE"
                print_message "SUCCESS" "Автоматическая отправка установлена на: ${BOLD}${user_friendly_times% }${RESET}."
                ;;
            2)
                print_message "INFO" "Отключение автоматической отправки..."
                (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -
                
                if grep -q "^CRON_TIMES=" "$CONFIG_FILE"; then
                    sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                fi
                print_message "SUCCESS" "Автоматическая отправка успешно отключена."
                ;;
            0) break ;;
            *) print_message "ERROR" "Неверный ввод. Пожалуйста, выберите один из предложенных пунктов." ;;
        esac
        echo ""
        read -rp "Нажмите Enter для продолжения..."
    done
    echo ""
}

restore_backup() {
    clear
    echo ""
    echo "=== Восстановление из бэкапа ==="
    print_message "WARN" "Восстановление полностью перезапишет базу данных ${BOLD}Remnawave${RESET}"
    echo -e "Поместите файл бэкапа (${BOLD}*.tar.gz${RESET}) в папку: ${BOLD}${BACKUP_DIR}${RESET}"

    ENV_NODE_RESTORE_PATH="$REMNALABS_ROOT_DIR/$ENV_NODE_FILE"
    ENV_RESTORE_PATH="$REMNALABS_ROOT_DIR/$ENV_FILE"

    if ! compgen -G "$BACKUP_DIR/remnawave_backup_*.tar.gz" > /dev/null; then
        print_message "ERROR" "Ошибка: Не найдено файлов бэкапов в ${BOLD}${BACKUP_DIR}${RESET}. Пожалуйста, поместите файл бэкапа в этот каталог."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    readarray -t SORTED_BACKUP_FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)

    if [ ${#SORTED_BACKUP_FILES[@]} -eq 0 ]; then
        print_message "ERROR" "Ошибка: Не найдено файлов бэкапов в ${BOLD}${BACKUP_DIR}${RESET}."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

        echo ""
    echo "Выберите файл для восстановления:"
    local i=1
    for file in "${SORTED_BACKUP_FILES[@]}"; do
        echo "  $i) ${file##*/}"
        i=$((i+1))
    done
    echo "  0) Вернуться в главное меню"
    echo ""

    local user_choice
    local selected_index

    while true; do
        read -rp "Введите номер файла для восстановления (0 для выхода): " user_choice
        
        if [[ "$user_choice" == "0" ]]; then
            print_message "INFO" "Восстановление отменено пользователем. Возврат в главное меню."
            return
        fi

        if ! [[ "$user_choice" =~ ^[0-9]+$ ]]; then
            print_message "ERROR" "Неверный ввод. Пожалуйста, введите номер."
            continue
        fi

        selected_index=$((user_choice - 1))

        if (( selected_index >= 0 && selected_index < ${#SORTED_BACKUP_FILES[@]} )); then
            SELECTED_BACKUP="${SORTED_BACKUP_FILES[$selected_index]}"
            break
        else
            print_message "ERROR" "Неверный номер. Пожалуйста, выберите номер из списка."
        fi
    done

    print_message "WARN" "Вы уверены? Это удалит текущие данные. Введите ${GREEN}Y${RESET}/${RED}N${RESET} для подтверждения: "
    read -r confirm_restore
    echo ""

    if [[ "${confirm_restore,,}" != "y" ]]; then
        print_message "WARN" "Восстановление отменено пользователем."
        return
    fi
    
    clear
    print_message "INFO" "Начало процесса полного сброса и восстановления базы данных..."
    echo ""

    print_message "INFO" "Остановка контейнеров и удаление тома базы данных..."
    if ! cd "$REMNALABS_ROOT_DIR"; then
        print_message "ERROR" "Ошибка: Не удалось перейти в каталог ${BOLD}${REMNALABS_ROOT_DIR}${RESET}. Убедитесь, что файл ${BOLD}docker-compose.yml${RESET} находится там."
        return
    fi

    docker compose down || {
        print_message "WARN" "Предупреждение: Не удалось корректно остановить сервисы. Возможно, они уже остановлены."
    }

    if docker volume ls -q | grep -q "remnawave-db-data"; then
        if ! docker volume rm remnawave-db-data; then
            echo -e "${RED}❌ Критическая ошибка: Не удалось удалить том ${BOLD}'remnawave-db-data'${RESET}. Восстановление невозможно. Проверьте права или занятость тома.${RESET}"
            return
        fi
        print_message "SUCCESS" "Том ${BOLD}remnawave-db-data${RESET} успешно удален."
    else
        print_message "INFO" "Том ${BOLD}remnawave-db-data${RESET} не найден, пропуск удаления."
    fi
    echo ""

    print_message "INFO" "Запуск контейнера ${BOLD}remnawave-db${RESET} для инициализации..."
    if ! docker compose up -d remnawave-db; then
        echo -e "${RED}❌ Критическая ошибка: Не удалось запустить контейнер ${BOLD}'remnawave-db'${RESET}. Восстановление невозможно.${RESET}"
        return
    fi
    print_message "INFO" "Ожидание запуска контейнера ${BOLD}remnawave-db${RESET}..."
    sleep 10
    echo ""

    if ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        echo -e "${RED}❌ Критическая ошибка: Контейнер ${BOLD}'remnawave-db'${RESET} все еще не запущен после попытки старта. Восстановление невозможно.${RESET}"
        return
    fi
    print_message "SUCCESS" "Контейнер ${BOLD}remnawave-db${RESET} успешно запущен."
    echo ""

    clear
    print_message "WARN" "${YELLOW}ПРОВЕРКА${RESET}"
    echo -e "Убедитесь, что имя пользователя PostgreSQL в ${BOLD}.env${RESET} скрипта указано верно."
    echo "Это крайне важно для успешного восстановления!"
    echo "Вы проверили и подтверждаете, что настройки верны?"
    echo -e "Введите ${GREEN}Y${RESET}/${RED}N${RESET} для подтверждения:"
    read -r confirm_db_settings
    echo ""

    if [[ "${confirm_db_settings,,}" != "y" ]]; then
        print_message "WARN" "Восстановление отменено пользователем."
        return
    fi

    if ! docker exec -i remnawave-db psql -U "$DB_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
        echo -e "${RED}❌ Ошибка: Не удалось подключиться к базе данных ${BOLD}'postgres'${RESET} в контейнере ${BOLD}'remnawave-db'${RESET} с пользователем '${BOLD}${DB_USER}${RESET}'.${RESET}"
        echo "  Проверьте имя пользователя БД в ${BOLD}${CONFIG_FILE}${RESET} и доступность контейнера."
        return
    fi
    print_message "SUCCESS" "Успешное подключение к базе данных ${BOLD}postgres${RESET} в контейнере ${BOLD}remnawave-db${RESET}."
    echo ""


    print_message "INFO" "Распаковка архива бэкапа..."
    local temp_restore_dir="$BACKUP_DIR/restore_temp_$$"
    mkdir -p "$temp_restore_dir"
    if ! tar -xzf "$SELECTED_BACKUP" -C "$temp_restore_dir"; then
        STATUS=$?
        echo -e "${RED}❌ Ошибка при распаковке архива ${BOLD}${SELECTED_BACKUP##*/}${RESET}. Код выхода: ${BOLD}$STATUS${RESET}. Возможно, архив поврежден.${RESET}"
        send_telegram_message "❌ Ошибка при распаковке архива: ${BOLD}${SELECTED_BACKUP##*/}${RESET}. Код выхода: ${BOLD}${STATUS}${RESET}" "None"
        rm -rf "$temp_restore_dir"
        exit $STATUS
    fi
    print_message "SUCCESS" "Архив успешно распакован во временную директорию."
    echo ""

    if [ -f "$temp_restore_dir/$ENV_NODE_FILE" ]; then
        print_message "INFO" "  Обнаружен файл ${BOLD}${ENV_NODE_FILE}${RESET} в архиве. Перемещаем его в ${BOLD}${ENV_NODE_RESTORE_PATH}${RESET}."
        mv "$temp_restore_dir/$ENV_NODE_FILE" "$ENV_NODE_RESTORE_PATH" || {
            echo -e "${RED}❌ Ошибка при перемещении ${BOLD}${ENV_NODE_FILE}${RESET}. Проверьте права доступа.${RESET}"
            send_telegram_message "❌ Ошибка: Не удалось переместить ${BOLD}${ENV_NODE_FILE}${RESET} при восстановлении." "None"
            rm -rf "$temp_restore_dir"
            exit 1;
        }
        print_message "SUCCESS" "  Файл ${BOLD}${ENV_NODE_FILE}${RESET} успешно перемещен."
    else
        print_message "WARN" "  Внимание: Файл ${BOLD}${ENV_NODE_FILE}${RESET} не найден в архиве. Продолжаем без него."
    fi

    if [ -f "$temp_restore_dir/$ENV_FILE" ]; then
        print_message "INFO" "  Обнаружен файл ${BOLD}${ENV_FILE}${RESET} в архиве. Перемещаем его в ${BOLD}${ENV_RESTORE_PATH}${RESET}."
        mv "$temp_restore_dir/$ENV_FILE" "$ENV_RESTORE_PATH" || {
            echo -e "${RED}❌ Ошибка при перемещении ${BOLD}${ENV_FILE}${RESET}. Проверьте права доступа.${RESET}"
            send_telegram_message "❌ Ошибка: Не удалось переместить ${BOLD}${ENV_FILE}${RESET} при восстановлении." "None"
            rm -rf "$temp_restore_dir"
            exit 1;
        }
        print_message "SUCCESS" "  Файл ${BOLD}${ENV_FILE}${RESET} успешно перемещен."
    else
        print_message "WARN" "  Внимание: Файл ${BOLD}${ENV_FILE}${RESET} не найден в архиве. Продолжаем без него."
    fi
    echo ""


    DUMP_FILE_GZ=$(find "$temp_restore_dir" -name "dump_*.sql.gz" | sort | tail -n 1)

    if [ ! -f "$DUMP_FILE_GZ" ]; then
        echo -e "${RED}❌ Ошибка: Не найден файл дампа (${BOLD}*.sql.gz${RESET}) после распаковки. Архив, возможно, поврежден или некорректен.${RESET}"
        send_telegram_message "❌ Ошибка: Не найден файл дампа после распаковки из ${BOLD}${SELECTED_BACKUP##*/}${RESET}" "None"
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    print_message "INFO" "Распаковка SQL-дампа: ${BOLD}${DUMP_FILE_GZ}${RESET}..."
    if ! gunzip "$DUMP_FILE_GZ"; then
        STATUS=$?
        echo -e "${RED}❌ Ошибка при распаковке SQL-дампа. Код выхода: ${BOLD}$STATUS${RESET}. Возможно, файл поврежден.${RESET}"
        send_telegram_message "❌ Ошибка при распаковке SQL-дампа: ${BOLD}${DUMP_FILE_GZ##*/}${RESET}. Код выхода: ${BOLD}${STATUS}${RESET}" "None"
        rm -rf "$temp_restore_dir"
        exit $STATUS
    fi
    print_message "SUCCESS" "SQL-дамп успешно распакован."
    echo ""

    SQL_FILE="${DUMP_FILE_GZ%.gz}"

    if [ ! -f "$SQL_FILE" ]; then
        echo -e "${RED}❌ Ошибка: Распакованный SQL-файл не найден. Это указывает на проблему с распаковкой.${RESET}"
        send_telegram_message "❌ Ошибка: Распакованный SQL-файл не найден." "None"
        rm -rf "$temp_restore_dir"
        exit 1
    fi

        local RESTORE_LOG_FILE="/var/log/rw-restore.log"

    print_message "INFO" "Восстановление базы данных из файла: ${BOLD}${SQL_FILE}${RESET}..."
    
    : > "$RESTORE_LOG_FILE"

    if cat "$SQL_FILE" | docker exec -i "remnawave-db" psql -q -U "$DB_USER" > /dev/null 2>>"$RESTORE_LOG_FILE"; then
        print_message "SUCCESS" "Импорт базы данных успешно завершен."
        local restore_success_prefix="✅ Восстановление Remnawave DB успешно завершено из файла: "
        local restored_filename="${SELECTED_BACKUP##*/}"
        send_telegram_message "${restore_success_prefix}${restored_filename}"
    else
        STATUS=$?
        local error_details=""
        if [[ -s "$RESTORE_LOG_FILE" ]]; then
            error_details=$(cat "$RESTORE_LOG_FILE")
            print_message "ERROR" "Ошибка при импорте базы данных. Код выхода: ${BOLD}$STATUS${RESET}."
            print_message "ERROR" "Подробности ошибки (см. ${BOLD}$RESTORE_LOG_FILE${RESET}):"
            echo "$error_details"
        else
            print_message "ERROR" "Ошибка при импорте базы данных. Код выхода: ${BOLD}$STATUS${RESET}. Деталей ошибки нет в логе ${BOLD}$RESTORE_LOG_FILE${RESET}."
        fi
        
        local restore_error_prefix="❌ Ошибка при импорте Remnawave DB из файла: "
        local restored_filename_error="${SELECTED_BACKUP##*/}"
        local error_suffix=". Код выхода: ${BOLD}${STATUS}${RESET}."
        
        if [[ -n "$error_details" ]]; then
            error_suffix+="\nПодробности: $error_details"
        fi

        send_telegram_message "${restore_error_prefix}${restored_filename_error}${error_suffix}"
        
        print_message "ERROR" "ОШИБКА: Восстановление завершилось с ошибкой. SQL-файл не удалён: ${BOLD}${SQL_FILE}${RESET} (во временном каталоге ${BOLD}${temp_restore_dir}${RESET})."
        
        return
    fi

    echo ""

    print_message "INFO" "Очистка временных файлов восстановления..."
    rm -rf "$temp_restore_dir"
    print_message "SUCCESS" "Временные файлы восстановления успешно удалены."
    echo ""

    print_message "INFO" "Перезапуск всех сервисов ${BOLD}Remnawave${RESET} и вывод логов..."
    if ! docker compose down; then
        print_message "WARN" "Предупреждение: Не удалось остановить сервисы Docker Compose перед полным запуском. Возможно, некоторые уже остановлены."
    fi

    if ! docker compose up -d; then
        echo -e "${RED}❌ Критическая ошибка: Не удалось запустить все сервисы Docker Compose после восстановления. Проверьте файлы compose.${RESET}"
        return
    else
        print_message "SUCCESS" "Все сервисы ${BOLD}Remnawave${RESET} успешно запущены."
    fi
    echo ""
    read -rp "Нажмите Enter для продолжения..."
}

update_script() {
    print_message "INFO" "Начинаю процесс обновления скрипта..."
    echo ""
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}⛔ Для обновления скрипта требуются права root. Пожалуйста, запустите с '${BOLD}sudo'${RESET}.${RESET}"
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    TEMP_SCRIPT_PATH="${INSTALL_DIR}/backup-restore.sh.tmp"
    print_message "INFO" "Загрузка последней версии скрипта с GitHub..."

    if curl -fsSL "$SCRIPT_REPO_URL" -o "$TEMP_SCRIPT_PATH"; then
        if [[ -s "$TEMP_SCRIPT_PATH" ]] && head -n 1 "$TEMP_SCRIPT_PATH" | grep -q -e '^#!.*bash'; then
            if cmp -s "$SCRIPT_PATH" "$TEMP_SCRIPT_PATH"; then
                print_message "INFO" "У вас уже установлена последняя версия скрипта. Обновление не требуется."
                rm -f "$TEMP_SCRIPT_PATH"
                read -rp "Нажмите Enter для продолжения..."
                return
            fi

            print_message "SUCCESS" "Загруженный скрипт успешно проверен."
            echo ""

            print_message "INFO" "Удаление старых резервных копий скрипта..."
            find "$(dirname "$SCRIPT_PATH")" -maxdepth 1 -name "${SCRIPT_NAME}.bak.*" -type f -delete
            print_message "SUCCESS" "Старые резервные копии скрипта удалены."
            echo ""
            
            BACKUP_PATH_SCRIPT="${SCRIPT_PATH}.bak.$(date +%s)"
            print_message "INFO" "Создание резервной копии текущего скрипта..."
            cp "$SCRIPT_PATH" "$BACKUP_PATH_SCRIPT" || {
                echo -e "${RED}❌ Не удалось создать резервную копию ${BOLD}${SCRIPT_PATH}${RESET}. Обновление отменено.${RESET}"
                rm -f "$TEMP_SCRIPT_PATH"
                read -rp "Нажмите Enter для продолжения..."
                return
            }
            print_message "SUCCESS" "Резервная копия текущего скрипта успешно создана."
            echo ""

            mv "$TEMP_SCRIPT_PATH" "$SCRIPT_PATH" || {
                echo -e "${RED}❌ Ошибка перемещения временного файла в ${BOLD}${SCRIPT_PATH}${RESET}. Пожалуйста, проверьте права доступа.${RESET}"
                echo -e "${YELLOW}⚠️ Восстановление из резервной копии ${BOLD}${BACKUP_PATH_SCRIPT}${RESET}...${RESET}"
                mv "$BACKUP_PATH_SCRIPT" "$SCRIPT_PATH"
                rm -f "$TEMP_SCRIPT_PATH"
                read -rp "Нажмите Enter для продолжения..."
                return
            }
            chmod +x "$SCRIPT_PATH"
            print_message "SUCCESS" "Скрипт успешно обновлен до последней версии."
            echo ""
            print_message "INFO" "Для применения изменений скрипт будет перезапущен..."
            read -rp "Нажмите Enter для перезапуска."
            exec "$SCRIPT_PATH" "$@"
            exit 0
        else
            echo -e "${RED}❌ Ошибка: Загруженный файл пуст или не является исполняемым bash-скриптом. Обновление невозможно.${RESET}"
            rm -f "$TEMP_SCRIPT_PATH"
        fi
    else
        echo -e "${RED}❌ Ошибка при загрузке новой версии с GitHub. Проверьте URL или сетевое соединение.${RESET}"
        rm -f "$TEMP_SCRIPT_PATH"
    fi
    read -rp "Нажмите Enter для продолжения..."
    echo ""
}

remove_script() {
    print_message "WARN" "ВНИМАНИЕ! Будут удалены: "
    echo  " - Скрипт"
    echo  " - Каталог установки и все бэкапы"
    echo  " - Символическая ссылка (если существует)"
    echo  " - Задачи cron"
    echo ""
    echo -e -n "Вы уверены, что хотите продолжить? Введите ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: "
    read -r confirm
    echo ""
    
    if [[ "${confirm,,}" != "y" ]]; then
    print_message "WARN" "Удаление отменено."
    read -rp "Нажмите Enter для продолжения..."
    return
    fi

    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "Для полного удаления требуются права root. Пожалуйста, запустите с ${BOLD}sudo${RESET}."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    print_message "INFO" "Удаление cron-задач..."
    if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH backup"; then
        (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -
        print_message "SUCCESS" "Задачи cron для автоматического бэкапа удалены."
    else
        print_message "INFO" "Задачи cron для автоматического бэкапа не найдены."
    fi
    echo ""

    print_message "INFO" "Удаление символической ссылки..."
    if [[ -L "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH" && print_message "SUCCESS" "Символическая ссылка ${BOLD}${SYMLINK_PATH}${RESET} удалена." || print_message "WARN" "Не удалось удалить символическую ссылку ${BOLD}${SYMLINK_PATH}${RESET}. Возможно, потребуется ручное удаление."
    elif [[ -e "$SYMLINK_PATH" ]]; then
        print_message "WARN" "${BOLD}${SYMLINK_PATH}${RESET} существует, но не является символической ссылкой. Рекомендуется проверить и удалить вручную."
    else
        print_message "INFO" "Символическая ссылка ${BOLD}${SYMLINK_PATH}${RESET} не найдена."
    fi
    echo ""

    print_message "INFO" "Удаление каталога установки и всех данных..."
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR" && print_message "SUCCESS" "Каталог установки ${BOLD}${INSTALL_DIR}${RESET} (включая скрипт, конфигурацию, бэкапы) удален." || echo -e "${RED}❌ Ошибка при удалении каталога ${BOLD}${INSTALL_DIR}${RESET}. Возможно, потребуются права 'root' или каталог занят.${RESET}"
    else
        print_message "INFO" "Каталог установки ${BOLD}${INSTALL_DIR}${RESET} не найден."
    fi
    echo ""

    print_message "SUCCESS" "Процесс удаления завершен."
    exit 0
}

main_menu() {
    while true; do
        clear
        print_ascii_art
        echo "========= Главное меню ========="
        echo "   1) 💾 Создать бэкап вручную"
        echo "   2) ⏰ Настройка автоматической отправки и уведомлений"
        echo "   3) ♻️ Восстановление из бэкапа"
        echo "   4) 🔄 Обновить скрипт"
        echo "   5) 🗑️ Удалить скрипт"
        echo "   6) ❌ Выход"
        echo -e "   —  🚀 Быстрый запуск: ${BOLD}rw-backup${RESET} доступен из любой точки системы"
        echo ""

        read -rp "Выберите пункт: " choice
        echo ""
        case $choice in
            1) create_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            2) setup_auto_send ;;
            3) restore_backup ;;
            4) update_script ;;
            5) remove_script ;;
            6) echo "Выход..."; exit 0 ;;
            *) print_message "ERROR" "Неверный ввод. Пожалуйста, выберите один из предложенных пунктов." ; read -rp "Нажмите Enter для продолжения..." ;;
        esac
    done
}

if [[ -z "$1" ]]; then
    install_dependencies
    load_or_create_config
    setup_symlink
    main_menu
elif [[ "$1" == "backup" ]]; then
    load_or_create_config
    create_backup
elif [[ "$1" == "restore" ]]; then
    load_or_create_config
    restore_backup
elif [[ "$1" == "update" ]]; then
    update_script
elif [[ "$1" == "remove" ]]; then
    remove_script
else
    echo -e "${RED}❌ Неверное использование. Доступные команды: ${BOLD}${0} [backup|restore|update|remove]${RESET}${RESET}"
    exit 1
fi
