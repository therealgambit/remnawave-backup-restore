# Remnawave Backup & Restore (by distillium)
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
sudo mkdir -p /opt/rw-backup-restore && sudo curl -sSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/refs/heads/main/backup-restore.sh -o /opt/rw-backup-restore/backup_and_notify.sh && sudo chmod +x /opt/rw-backup-restore/backup_and_notify.sh && sudo /opt/rw-backup-restore/backup_and_notify.sh
```
## Команды:
- `rw-backup` — быстрый доступ (при активации)
