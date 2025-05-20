# Remnawave Backup & Restore (beta)
#       (by distillium)
Скрипт автоматизирует резервное копирование и восстановление базы данных.

![screenshot](screenshot.png)

## Функции:
- интерактивное меню
- уведомления в Telegram бота с прикрепленным бэкапом
- создание бэкапа вручную
- настройка автоматического запуска по расписанию
- восстановление из файла
- активация команды быстрого доступа
- реализована политика хранения бэкапов

## Установка:
```
sudo mkdir -p /opt/rw-backup-restore && sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh)"
```
## Команды:
- `rw-backup` — быстрый доступ (при активации)
