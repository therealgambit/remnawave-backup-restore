# Remnawave Backup & Resore (by distillium)
Скрипт автоматизирует резервное копирование и восстановление базы данных.

![screenshot](screenshot.png)

## Функции:
• интерактивное меню\n
• уведомления в Telegram бота с прикрепленным бэкапом\n
• создание бэкапа вручную\n
• настройка автоматического запуска по расписанию\n
• восстановление из файла\n
• активация команды быстрого доступа\n
• реализована политика хранения бэкапов

## Установка:
```
sudo mkdir -p /opt/rw-backup-restore && sudo curl -sSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/refs/heads/main/backup-restore.sh -o /opt/rw-backup-restore/backup_and_notify.sh && sudo chmod +x /opt/rw-backup-restore/backup_and_notify.sh && sudo /opt/rw-backup-restore/backup_and_notify.sh
```
## Команды:
- `rw-backup` — быстрый доступ (при активации)
