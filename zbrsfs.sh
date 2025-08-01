#!/bin/bash

set -e

BACKUP_DIR="/backup/zabbix"
BACKUP_PATH="$BACKUP_DIR/zabbix_backup.tar.gz"
#TEMP_DIR=$(mktemp -d)
TEMP_DIR="$BACKUP_DIR/temp"
MYSQL_CNF="/root/.my.cnf"

# Проверка и установка зависимостей
check_dependencies() {
    local missing=()
    
    for cmd in tar mysqldump mysql grep systemctl; do
        if ! command -v $cmd &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Установка недостающих пакетов: ${missing[*]}"
        dnf install -y ${missing[@]}
    fi
}

# Проверка root-доступа к MySQL
check_mysql_root_access() {
    if ! mysql -e "SHOW DATABASES" &>/dev/null; then
        echo "Внимание: требуется пароль root для MySQL"
        echo -n "Введите пароль root для MySQL: "
        IFS= read -rs mysql_root_password
        echo

        MYSQL_CNF_TMP=$(mktemp)
        cat > "$MYSQL_CNF_TMP" <<EOF
[client]
user=root
password=$mysql_root_password
EOF

        if ! mysql --defaults-extra-file="$MYSQL_CNF_TMP" -e "SHOW DATABASES" &>/dev/null; then
            echo "ОШИБКА: Неверный пароль root для MySQL"
            rm -f "$MYSQL_CNF_TMP"
            exit 1
        fi

        cp "$MYSQL_CNF_TMP" "$MYSQL_CNF"
        chmod 600 "$MYSQL_CNF"
        rm -f "$MYSQL_CNF_TMP"
        echo "Файл конфигурации MySQL создан: $MYSQL_CNF"
    else
        # root-доступ есть без пароля, но файл может отсутствовать
        if [ ! -f "$MYSQL_CNF" ]; then
            cat > "$MYSQL_CNF" <<EOF
[client]
user=root
EOF
            chmod 600 "$MYSQL_CNF"
            echo "Файл конфигурации MySQL создан без пароля: $MYSQL_CNF"
        fi
    fi
}

# Функция резервного копирования
perform_backup() {
    local custom_backup_path="$1"
    echo "[$(date +'%F %T')] Запуск процедуры бэкапа"

    # Проверка root-доступа к MySQL и создание .my.cnf при необходимости
    check_mysql_root_access

    mkdir -p "$BACKUP_DIR"
    mkdir -p "$TEMP_DIR"
    systemctl stop zabbix-server zabbix-agent

    # Получение параметров БД
    db_user=$(grep -oP '^DBUser=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_password=$(grep -oP '^DBPassword=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_name=$(grep -oP '^DBName=\K\S+' /etc/zabbix/zabbix_server.conf)

    # Формируем имя файла бэкапа с датой и временем или используем custom путь
    if [ -n "$custom_backup_path" ]; then
        BACKUP_PATH="$custom_backup_path"
    else
        BACKUP_FILENAME="zabbix_backup_$(date +'%d-%m-%Y_%H-%M').tar.gz"
        BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"
    fi

    # Создание дампа БД
    echo "[$(date +'%F %T')] Создание дампа базы данных..."
    mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --no-tablespaces "$db_name" > "$TEMP_DIR/zabbix_db.sql"

    # Копирование конфигураций
    echo "[$(date +'%F %T')] Копирование конфигурационных файлов..."
    cp -a /etc/zabbix "$TEMP_DIR/conf_etc_zabbix"
    cp -a /etc/nginx/conf.d/zabbix.conf "$TEMP_DIR/nginx_zabbix.conf" 2>/dev/null || :
    cp -a /etc/php-fpm.d/zabbix.conf "$TEMP_DIR/php-fpm_zabbix.conf" 2>/dev/null || :

    # Создание архива
    echo "[$(date +'%F %T')] Упаковка архива..."
    tar -czf "$BACKUP_PATH" -C "$TEMP_DIR" .

    systemctl start zabbix-server zabbix-agent
    echo "[$(date +'%F %T')] Бэкап успешно создан: $BACKUP_PATH"
    rm -rf "$TEMP_DIR"

    # Создание/обновление симлинка на последний бэкап только если не custom путь
    if [ -z "$custom_backup_path" ]; then
        ln -sf "$(basename "$BACKUP_PATH")" "$BACKUP_DIR/latest"
    fi
}

# Функция восстановления с использованием root-доступа
perform_restore() {
    local restore_path="$1"

    echo "[$(date +'%F %T')] Запуск процедуры восстановления"
    
    mkdir -p "$TEMP_DIR"

    # Проверка root-доступа к MySQL
    check_mysql_root_access

    if [ ! -f "$restore_path" ]; then
        echo "ОШИБКА: Файл бэкапа не найден: $restore_path"
        echo "Проверьте путь: $restore_path"
        exit 1
    fi

    systemctl stop zabbix-server zabbix-agent nginx

    # Распаковка архива
    echo "[$(date +'%F %T')] Распаковка архива..."
    tar -xzf "$restore_path" -C "$TEMP_DIR"
    
    # Получение параметров БД
    db_user=$(grep -oP '^DBUser=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_password=$(grep -oP '^DBPassword=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_name=$(grep -oP '^DBName=\K\S+' /etc/zabbix/zabbix_server.conf)
    
    # Пересоздание базы данных
    echo "[$(date +'%F %T')] Пересоздание базы данных..."
    mysql --defaults-extra-file="$MYSQL_CNF" -e "DROP DATABASE IF EXISTS \`$db_name\`;"
    mysql --defaults-extra-file="$MYSQL_CNF" -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8 COLLATE utf8_bin;"
    
    # Настройка пользователя Zabbix
    echo "[$(date +'%F %T')] Настройка пользователя Zabbix..."
    mysql --defaults-extra-file="$MYSQL_CNF" -e "DROP USER IF EXISTS '$db_user'@'localhost';"
    mysql --defaults-extra-file="$MYSQL_CNF" -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
    mysql --defaults-extra-file="$MYSQL_CNF" -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';"
    mysql --defaults-extra-file="$MYSQL_CNF" -e "FLUSH PRIVILEGES;"
    
    # Восстановление данных
    echo "[$(date +'%F %T')] Восстановление базы данных..."
    mysql --defaults-extra-file="$MYSQL_CNF" "$db_name" < "$TEMP_DIR/zabbix_db.sql"
    
    # Восстановление конфигов
    echo "[$(date +'%F %T')] Восстановление конфигураций..."
    rm -rf /etc/zabbix/*
    cp -a "$TEMP_DIR/conf_etc_zabbix"/* /etc/zabbix/
    
    if [ -f "$TEMP_DIR/nginx_zabbix.conf" ]; then
        cp -a "$TEMP_DIR/nginx_zabbix.conf" /etc/nginx/conf.d/
    fi
    
    if [ -f "$TEMP_DIR/php-fpm_zabbix.conf" ]; then
        cp -a "$TEMP_DIR/php-fpm_zabbix.conf" /etc/php-fpm.d/
    fi
    
    # Запуск служб
    systemctl start zabbix-server zabbix-agent nginx
    
    echo "[$(date +'%F %T')] Восстановление успешно завершено"
    rm -rf "$TEMP_DIR"
}

# Проверка прав пользователя
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: скрипт требует запуска с правами root (sudo)"
    exit 1
fi

# Проверка параметров
if [ $# -lt 1 ]; then
    echo "Использование: $0 [backup|restore] [--backup=/path/to/backup.tar.gz]"
    exit 1
fi

# Проверяем зависимости перед выполнением
check_dependencies

# Выбор операции
case "$1" in
    backup)
        # Если указан параметр --backup=...
        if [[ "$2" =~ ^--backup= ]]; then
            perform_backup "${2#--backup=}"
        else
            perform_backup
        fi
        ;;
    restore)
        # По умолчанию используем симлинк latest
        RESTORE_BACKUP="$BACKUP_DIR/latest"
        # Если указан параметр --backup=...
        if [[ "$2" =~ ^--backup= ]]; then
            RESTORE_BACKUP="${2#--backup=}"
        fi
        perform_restore "$RESTORE_BACKUP"
        ;;
    *)
        echo "Неизвестная команда: $1"
        echo "Допустимые команды: backup [--backup=/path/to/backup.tar.gz], restore [--backup=/path/to/backup.tar.gz]"
        exit 1
        ;;
esac