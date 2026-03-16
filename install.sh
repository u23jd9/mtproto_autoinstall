#!/bin/bash

# ============================================
# MTProxy Installer Script
# Version: 2.0
# Author: Adapted for manual IPv4 setup
# ============================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Конфигурация
INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="MTProxy"
PROXY_PORT="8443"
STATS_PORT="8888"
PROXY_SECRET=""
PUBLIC_IP=""
PRIVATE_IP=""

# Функции вывода
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $1"; }
warning() { echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1"; }
info() { echo -e "${CYAN}[ИНФО]${NC} $1"; }

# Проверка root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Запустите скрипт от root (sudo)."
        exit 1
    fi
}

# Ввод IP адресов (только ручной)
input_ips() {
    echo -e "\n${BLUE}--- Ввод IP адресов ---${NC}"
    read -p "Введите публичный IPv4 адрес сервера: " PUBLIC_IP
    if [[ -z "$PUBLIC_IP" ]] || ! [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Неверный формат IPv4."
        return 1
    fi

    read -p "Введите приватный IPv4 адрес (если сервер за NAT, иначе оставьте пустым): " PRIVATE_IP
    if [[ -z "$PRIVATE_IP" ]]; then
        PRIVATE_IP="$PUBLIC_IP"
        info "Приватный IP не задан, будет использован публичный: $PRIVATE_IP"
    elif ! [[ $PRIVATE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Неверный формат приватного IPv4."
        return 1
    fi

    log "IP адреса сохранены: публичный=$PUBLIC_IP, приватный=$PRIVATE_IP"
    return 0
}

# Полная очистка предыдущих установок
cleanup() {
    log "Очистка предыдущих установок..."
    systemctl stop $SERVICE_NAME 2>/dev/null
    systemctl disable $SERVICE_NAME 2>/dev/null
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    rm -rf $INSTALL_DIR
    userdel -r mtproxy 2>/dev/null
    rm -f /etc/cron.d/mtproxy-update
    iptables -D INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport $STATS_PORT -j ACCEPT 2>/dev/null
    systemctl daemon-reload
    log "Очистка завершена."
}

# Установка зависимостей
install_deps() {
    log "Установка зависимостей..."
    apt-get update
    apt-get install -y git curl build-essential libssl-dev zlib1g-dev xxd cron iptables-persistent
    if [[ $? -ne 0 ]]; then
        error "Ошибка установки зависимостей."
        return 1
    fi
    return 0
}

# Сборка MTProxy
build_proxy() {
    log "Клонирование и сборка MTProxy..."
    rm -rf /tmp/MTProxy
    git clone https://github.com/GetPageSpeed/MTProxy /tmp/MTProxy
    cd /tmp/MTProxy
    sed -i 's/COMMON_CFLAGS=/COMMON_CFLAGS=-fcommon /' Makefile
    sed -i 's/COMMON_LDFLAGS=/COMMON_LDFLAGS=-fcommon /' Makefile
    make clean
    make
    if [[ $? -ne 0 ]]; then
        error "Ошибка сборки."
        return 1
    fi
    mkdir -p $INSTALL_DIR
    cp objs/bin/mtproto-proxy $INSTALL_DIR/
    log "Сборка завершена."
    return 0
}

# Генерация секрета
gen_secret() {
    PROXY_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    log "Секретный ключ сгенерирован."
}

# Настройка конфигурации
setup_config() {
    log "Загрузка конфигурационных файлов Telegram..."
    cd $INSTALL_DIR
    curl -s https://core.telegram.org/getProxySecret -o proxy-secret
    curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
    useradd -r -s /bin/false mtproxy 2>/dev/null
    chown -R mtproxy:mtproxy $INSTALL_DIR
    chmod +x mtproto-proxy
    log "Конфигурация готова."
}

# Создание systemd сервиса
create_service() {
    log "Создание systemd сервиса..."
    local NAT_INFO=""
    if [[ "$PUBLIC_IP" != "$PRIVATE_IP" ]]; then
        NAT_INFO="--nat-info $PRIVATE_IP:$PUBLIC_IP"
        info "Добавлен NAT-info: $PRIVATE_IP:$PUBLIC_IP"
    fi

    cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/mtproto-proxy -u mtproxy -p $STATS_PORT -H $PROXY_PORT -S $PROXY_SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1 --http-stats $NAT_INFO
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "Сервис создан."
}

# Открытие портов в firewall
open_ports() {
    log "Настройка firewall..."
    iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT
    iptables -I INPUT -p tcp --dport $STATS_PORT -j ACCEPT
    # Сохраняем правила (для debian/ubuntu с iptables-persistent)
    if command -v iptables-save >/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    log "Порты $PROXY_PORT и $STATS_PORT открыты."
}

# Запуск сервиса
start_service() {
    log "Запуск сервиса..."
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    sleep 3
    if systemctl is-active --quiet $SERVICE_NAME; then
        log "Сервис успешно запущен."
        return 0
    else
        error "Не удалось запустить сервис. Проверьте логи: journalctl -u $SERVICE_NAME"
        return 1
    fi
}

# Создание ссылок для подключения
generate_links() {
    local TG_LINK="tg://proxy?server=$PUBLIC_IP&port=$PROXY_PORT&secret=$PROXY_SECRET"
    local HTTP_LINK="https://t.me/proxy?server=$PUBLIC_IP&port=$PROXY_PORT&secret=$PROXY_SECRET"
    local PADDING_LINK="tg://proxy?server=$PUBLIC_IP&port=$PROXY_PORT&secret=dd$PROXY_SECRET"

    cat > $INSTALL_DIR/links.txt <<EOF
========================================
      MTProxy готов к использованию
========================================

Обычная ссылка (TG): $TG_LINK
Обычная ссылка (HTTP): $HTTP_LINK

Ссылка с рандомным паддингом: $PADDING_LINK

Информация:
- Сервер: $PUBLIC_IP
- Порт: $PROXY_PORT
- Секрет: $PROXY_SECRET
- Статистика: http://$PUBLIC_IP:$STATS_PORT/stats

Сохраните эти данные в надёжном месте.
========================================
EOF
    chmod 644 $INSTALL_DIR/links.txt
    echo -e "\n${GREEN}$(cat $INSTALL_DIR/links.txt)${NC}"
}

# Настройка cron для обновления конфигурации
setup_cron() {
    log "Настройка ежедневного обновления конфигурации (cron)..."
    cat > /etc/cron.d/mtproxy-update <<EOF
0 4 * * * root curl -s https://core.telegram.org/getProxyConfig -o $INSTALL_DIR/proxy-multi.conf && chown mtproxy:mtproxy $INSTALL_DIR/proxy-multi.conf && systemctl restart $SERVICE_NAME >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/mtproxy-update
    log "Cron настроен."
}

# Добавление объявления
add_ad() {
    echo -e "${YELLOW}--- Добавление объявления в прокси ---${NC}"
    read -p "Введите текст объявления: " AD_TEXT
    if [[ -z "$AD_TEXT" ]]; then
        error "Текст не может быть пустым."
        return
    fi
    # Остановим сервис, обновим параметр и запустим
    systemctl stop $SERVICE_NAME
    local SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    local EXEC_START=$(grep "ExecStart=" "$SERVICE_FILE" | sed 's/^ExecStart=//')
    # Убираем старые параметры объявления, если они были
    EXEC_START=$(echo "$EXEC_START" | sed 's/--advertisement[^ ]*//g')
    local NEW_EXEC_START="$EXEC_START --advertisement \"$AD_TEXT\""
    sed -i "s|ExecStart=.*|ExecStart=$NEW_EXEC_START|" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl start $SERVICE_NAME
    log "Объявление добавлено. Перезапуск сервиса выполнен."
}

# Показать статус
show_status() {
    echo -e "${BLUE}--- Статус MTProxy ---${NC}"
    if [[ ! -f $INSTALL_DIR/mtproto-proxy ]]; then
        echo "Прокси не установлен."
        return
    fi
    systemctl status $SERVICE_NAME --no-pager -l
    echo -e "\n${CYAN}Ссылки для подключения:${NC}"
    [[ -f $INSTALL_DIR/links.txt ]] && cat $INSTALL_DIR/links.txt || echo "Файл ссылок не найден."
}

# Диагностика проблем
diagnose() {
    echo -e "${YELLOW}--- Диагностика ---${NC}"
    echo "1. Проверка портов:"
    ss -tlnp | grep -E "($PROXY_PORT|$STATS_PORT)" || echo "Порты не прослушиваются."
    echo -e "\n2. Статус сервиса:"
    systemctl status $SERVICE_NAME --no-pager -l | head -15
    echo -e "\n3. Последние ошибки в логах:"
    journalctl -u $SERVICE_NAME --no-pager -n 10 | grep -i error || echo "Ошибок не найдено."
    echo -e "\n4. Проверка конфигурации:"
    ls -la $INSTALL_DIR/proxy-secret $INSTALL_DIR/proxy-multi.conf 2>/dev/null || echo "Файлы конфигурации отсутствуют."
}

# Полная деинсталляция
uninstall() {
    echo -e "${RED}--- Полная деинсталляция ---${NC}"
    read -p "Вы уверены? Это удалит все файлы и сервис. (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        cleanup
        log "Деинсталляция завершена."
    else
        log "Отменено."
    fi
}

# Основная функция установки
install() {
    echo -e "${GREEN}--- Установка MTProxy ---${NC}"
    input_ips || return 1
    cleanup
    install_deps || return 1
    build_proxy || return 1
    gen_secret
    setup_config
    create_service
    open_ports
    start_service || return 1
    generate_links
    setup_cron
    log "Установка успешно завершена!"
}

# Меню
menu() {
    while true; do
        clear
        echo -e "${BLUE}================================${NC}"
        echo -e "${GREEN}      MTProxy Управление        ${NC}"
        echo -e "${BLUE}================================${NC}"
        echo "1) Установить прокси"
        echo "2) Показать статус и ссылки"
        echo "3) Добавить объявление"
        echo "4) Диагностика"
        echo "5) Полная деинсталляция"
        echo "6) Выход"
        echo -e "${BLUE}================================${NC}"
        read -p "Выберите действие (1-6): " choice
        case $choice in
            1) install ;;
            2) show_status ;;
            3) add_ad ;;
            4) diagnose ;;
            5) uninstall ;;
            6) echo "Выход."; exit 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo -e "\nНажмите Enter для продолжения..."
        read
    done
}

# Запуск
check_root
menu