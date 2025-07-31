#!/bin/bash

set -e

BACKUP_DIR="/backup/zabbix/latest"
BACKUP_PATH="$BACKUP_DIR/zabbix_backup.tar.gz"
TEMP_DIR=$(mktemp -d)
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

# Проверка прав пользователя
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: скрипт требует запуска с правами root (sudo)"
    exit 1
fi

# Проверка параметров
if [ $# -ne 1 ]; then
    echo "Использование: $0 [backup|restore]"
    exit 1
fi

# Проверяем зависимости перед выполнением
check_dependencies

# Проверка root-доступа к MySQL
check_mysql_root_access() {
    if ! mysql -e "SHOW DATABASES" &>/dev/null; then
        echo "Внимание: требуется пароль root для MySQL"
        echo -n "Введите пароль root для MySQL: "
        IFS= read -rs mysql_root_password
        echo
        
        # Создаем временный файл конфигурации
        MYSQL_CNF_TMP=$(mktemp)
        cat > "$MYSQL_CNF_TMP" <<EOF
[client]
user=root
password='$mysql_root_password'
EOF
        
        # Проверка введенного пароля
        if ! mysql --defaults-extra-file="$MYSQL_CNF_TMP" -e "SHOW DATABASES" &>/dev/null; then
            echo "ОШИБКА: Неверный пароль root для MySQL"
            rm -f "$MYSQL_CNF_TMP"
            exit 1
        fi
        
        echo -e "\n[client]\nuser=root\npassword='$mysql_root_password'" | tee "$MYSQL_CNF" >/dev/null
        chmod 600 "$MYSQL_CNF"
        rm -f "$MYSQL_CNF_TMP"
        echo "Файл конфигурации MySQL создан: $MYSQL_CNF"
    fi
}

# Функция резервного копирования
perform_backup() {
    echo "[$(date +'%F %T')] Запуск процедуры бэкапа"
    
    mkdir -p "$BACKUP_DIR"
    systemctl stop zabbix-server zabbix-agent
    
    # Получение параметров БД
    db_user=$(grep -oP '^DBUser=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_password=$(grep -oP '^DBPassword=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_name=$(grep -oP '^DBName=\K\S+' /etc/zabbix/zabbix_server.conf)
    
    # Создание дампа БД
    echo "[$(date +'%F %T')] Создание дампа базы данных..."
    mysqldump --single-transaction --no-tablespaces -u"$db_user" -p"$db_password" "$db_name" > "$TEMP_DIR/zabbix_db.sql"
    
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
}

# Функция восстановления с использованием root-доступа
perform_restore() {
    echo "[$(date +'%F %T')] Запуск процедуры восстановления"
    
    # Проверка root-доступа к MySQL
    check_mysql_root_access
    
    if [ ! -f "$BACKUP_PATH" ]; then
        echo "ОШИБКА: Файл бэкапа не найден: $BACKUP_PATH"
        echo "Проверьте путь: $BACKUP_DIR"
        exit 1
    fi
    
    systemctl stop zabbix-server zabbix-agent nginx
    
    # Распаковка архива
    echo "[$(date +'%F %T')] Распаковка архива..."
    tar -xzf "$BACKUP_PATH" -C "$TEMP_DIR"
    
    # Получение параметров БД
    db_user=$(grep -oP '^DBUser=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_password=$(grep -oP '^DBPassword=\K\S+' /etc/zabbix/zabbix_server.conf)
    db_name=$(grep -oP '^DBName=\K\S+' /etc/zabbix/zabbix_server.conf)
    
    # Пересоздание базы данных
    echo "[$(date +'%F %T')] Пересоздание базы данных..."
    mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;"
    mysql -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8 COLLATE utf8_bin;"
    
    # Настройка пользователя Zabbix
    echo "[$(date +'%F %T')] Настройка пользователя Zabbix..."
    mysql -e "DROP USER IF EXISTS '$db_user'@'localhost';"
    mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
    mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Восстановление данных
    echo "[$(date +'%F %T')] Восстановление базы данных..."
    mysql "$db_name" < "$TEMP_DIR/zabbix_db.sql"
    
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

# Выбор операции
case "$1" in
    backup)
        perform_backup
        ;;
    restore)
        perform_restore
        ;;
    *)
        echo "Неизвестная команда: $1"
        echo "Допустимые команды: backup, restore"
        exit 1
        ;;
esac