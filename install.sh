#!/bin/bash

# ============================================
# MTProxy Manager
# Version: 3.0
# Author: Community Edition
# ============================================

# ---------- Цвета и стили ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# ---------- Конфигурация ----------
INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="MTProxy"
PROXY_PORT="8443"
STATS_PORT="8888"
PROXY_SECRET=""
PUBLIC_IP=""
PRIVATE_IP=""
AD_ID=""  # ID рекламы от @MTProxybot

# ---------- Функции вывода ----------
log() { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${CYAN}[ℹ]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
header() { echo -e "${BLUE}${BOLD}=== $1 ===${NC}"; }

# ---------- Проверка root ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться от root."
        exit 1
    fi
}

# ---------- Автоопределение IP (с поддержкой NAT) ----------
detect_ips() {
    header "ОПРЕДЕЛЕНИЕ IP АДРЕСОВ"
    
    # Публичный IPv4
    PUBLIC_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 ipinfo.io/ip 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null)
    if [[ -z "$PUBLIC_IP" ]]; then
        error "Не удалось определить публичный IP. Введите вручную."
        read -p "Введите публичный IPv4: " PUBLIC_IP
    else
        log "Публичный IP: $PUBLIC_IP"
    fi

    # Приватный IP (первый не-loopback интерфейс)
    PRIVATE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
    
    # Проверка на AWS Lightsail (метаданные)
    if curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null | grep -q "lightsail"; then
        AWS_PRIVATE_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
        if [[ -n "$AWS_PRIVATE_IP" ]]; then
            PRIVATE_IP="$AWS_PRIVATE_IP"
            warn "Обнаружен AWS Lightsail. Приватный IP: $PRIVATE_IP"
        fi
    fi

    if [[ -z "$PRIVATE_IP" ]]; then
        warn "Не удалось определить приватный IP, будем считать равным публичному."
        PRIVATE_IP="$PUBLIC_IP"
    else
        log "Приватный IP: $PRIVATE_IP"
    fi

    # Если они разные – предупреждение о NAT
    if [[ "$PUBLIC_IP" != "$PRIVATE_IP" ]]; then
        warn "Публичный и приватный IP различаются (NAT). Будет использован --nat-info"
    fi
}

# ---------- Полная очистка ----------
cleanup() {
    header "ОЧИСТКА"
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

# ---------- Установка зависимостей ----------
install_deps() {
    header "УСТАНОВКА ЗАВИСИМОСТЕЙ"
    apt-get update
    apt-get install -y git curl build-essential libssl-dev zlib1g-dev xxd cron iptables-persistent
    if [[ $? -eq 0 ]]; then
        log "Зависимости установлены."
    else
        error "Ошибка установки зависимостей."
        return 1
    fi
}

# ---------- Сборка MTProxy ----------
build_proxy() {
    header "СБОРКА MTProxy"
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
}

# ---------- Генерация секрета ----------
gen_secret() {
    PROXY_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    log "Секретный ключ сгенерирован: $PROXY_SECRET"
}

# ---------- Настройка конфигурации ----------
setup_config() {
    header "НАСТРОЙКА КОНФИГУРАЦИИ"
    cd $INSTALL_DIR
    curl -s https://core.telegram.org/getProxySecret -o proxy-secret
    curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
    useradd -r -s /bin/false mtproxy 2>/dev/null
    chown -R mtproxy:mtproxy $INSTALL_DIR
    chmod +x mtproto-proxy
    log "Конфигурация загружена."
}

# ---------- Создание systemd сервиса ----------
create_service() {
    header "СОЗДАНИЕ СЕРВИСА"
    local NAT_INFO=""
    if [[ "$PUBLIC_IP" != "$PRIVATE_IP" ]]; then
        NAT_INFO="--nat-info $PRIVATE_IP:$PUBLIC_IP"
        info "Добавлен NAT-info: $PRIVATE_IP:$PUBLIC_IP"
    fi

    local AD_PARAM=""
    if [[ -n "$AD_ID" ]]; then
        AD_PARAM="-P $AD_ID"
        info "Рекламный ID: $AD_ID"
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
ExecStart=$INSTALL_DIR/mtproto-proxy -u mtproxy -p $STATS_PORT -H $PROXY_PORT -S $PROXY_SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1 --http-stats $NAT_INFO $AD_PARAM
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

# ---------- Открытие портов ----------
open_ports() {
    header "НАСТРОЙКА FIREWALL"
    iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT
    iptables -I INPUT -p tcp --dport $STATS_PORT -j ACCEPT
    if command -v iptables-save >/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    log "Порты $PROXY_PORT и $STATS_PORT открыты."
}

# ---------- Запуск сервиса ----------
start_service() {
    header "ЗАПУСК СЕРВИСА"
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    sleep 3
    if systemctl is-active --quiet $SERVICE_NAME; then
        log "Сервис запущен."
    else
        error "Не удалось запустить сервис. Смотрите логи: journalctl -u $SERVICE_NAME"
        return 1
    fi
}

# ---------- Генерация ссылок ----------
generate_links() {
    header "ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ"
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
    echo -e "${GREEN}$(cat $INSTALL_DIR/links.txt)${NC}"
}

# ---------- Настройка cron ----------
setup_cron() {
    header "НАСТРОЙКА АВТООБНОВЛЕНИЯ"
    cat > /etc/cron.d/mtproxy-update <<EOF
0 4 * * * root curl -s https://core.telegram.org/getProxyConfig -o $INSTALL_DIR/proxy-multi.conf && chown mtproxy:mtproxy $INSTALL_DIR/proxy-multi.conf && systemctl restart $SERVICE_NAME >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/mtproxy-update
    log "Cron настроен (обновление в 4:00)."
}

# ---------- Запрос рекламного ID ----------
ask_ad_id() {
    echo -e "${YELLOW}Хотите подключить рекламу в прокси?${NC}"
    echo "Для этого нужно получить ID в боте @MTProxybot (напишите ему /start и создайте прокси)."
    read -p "Введите ID рекламы (или оставьте пустым, чтобы пропустить): " AD_ID
    if [[ -n "$AD_ID" ]]; then
        log "Рекламный ID сохранён: $AD_ID"
    else
        info "Реклама не будет подключена."
    fi
}

# ---------- Основная установка ----------
install() {
    clear
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${GREEN}${BOLD}         УСТАНОВКА MTProxy            ${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    detect_ips
    ask_ad_id
    cleanup
    install_deps || return
    build_proxy || return
    gen_secret
    setup_config
    create_service
    open_ports
    start_service || return
    generate_links
    setup_cron
    log "Установка успешно завершена!"
}

# ---------- Статусная панель ----------
status_panel() {
    clear
    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}         MTProxy СТАТУС                ${NC}"
    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
    
    if [[ ! -f $INSTALL_DIR/mtproto-proxy ]]; then
        echo -e "${RED}Прокси не установлен.${NC}"
        return
    fi

    # Статус сервиса
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e " ${GREEN}●${NC} Сервис: ${GREEN}активен${NC}"
    else
        echo -e " ${RED}●${NC} Сервис: ${RED}остановлен${NC}"
    fi

    # Основная информация
    if [[ -f $INSTALL_DIR/links.txt ]]; then
        SERVER_IP=$(grep "Сервер:" $INSTALL_DIR/links.txt | head -1 | awk '{print $2}')
        SECRET=$(grep "Секрет:" $INSTALL_DIR/links.txt | head -1 | awk '{print $2}')
        echo -e " ${CYAN}ℹ${NC} Публичный IP: ${WHITE}$SERVER_IP${NC}"
        echo -e " ${CYAN}ℹ${NC} Порт: ${WHITE}$PROXY_PORT${NC}"
        echo -e " ${CYAN}ℹ${NC} Секрет: ${WHITE}$SECRET${NC}"
    fi

    # Статистика
    STATS=$(curl -s http://127.0.0.1:$STATS_PORT/stats 2>/dev/null)
    if [[ -n "$STATS" ]]; then
        CONNS=$(echo "$STATS" | grep -o '"count":[0-9]*' | head -1 | cut -d':' -f2)
        TX=$(echo "$STATS" | grep -o '"tx_bytes":[0-9]*' | head -1 | cut -d':' -f2)
        RX=$(echo "$STATS" | grep -o '"rx_bytes":[0-9]*' | head -1 | cut -d':' -f2)
        echo -e " ${GREEN}📊${NC} Подключений: ${WHITE}${CONNS:-0}${NC}"
        echo -e " ${GREEN}📊${NC} Трафик: отправлено ${WHITE}$((TX/1024/1024)) MB${NC}, получено ${WHITE}$((RX/1024/1024)) MB${NC}"
    else
        echo -e " ${YELLOW}📊${NC} Статистика временно недоступна"
    fi

    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
}

# ---------- Управление сервисом ----------
manage_service() {
    while true; do
        clear
        status_panel
        echo ""
        echo -e "${YELLOW}Управление сервисом:${NC}"
        echo "1) Запустить"
        echo "2) Остановить"
        echo "3) Перезапустить"
        echo "4) Просмотр логов (journalctl)"
        echo "5) Назад в главное меню"
        read -p "Выберите действие: " svc_choice
        case $svc_choice in
            1) systemctl start $SERVICE_NAME; log "Сервис запущен." ;;
            2) systemctl stop $SERVICE_NAME; warn "Сервис остановлен." ;;
            3) systemctl restart $SERVICE_NAME; log "Сервис перезапущен." ;;
            4) journalctl -u $SERVICE_NAME -n 50 -f ;;
            5) break ;;
            *) error "Неверный выбор." ;;
        esac
        if [[ $svc_choice != 4 ]]; then
            echo -e "\nНажмите Enter..."
            read
        fi
    done
}

# ---------- Добавление/обновление рекламы ----------
manage_ad() {
    header "НАСТРОЙКА РЕКЛАМЫ"
    echo "Получить ID рекламы можно в боте @MTProxybot."
    read -p "Введите новый рекламный ID (или оставьте пустым для удаления): " NEW_AD_ID
    if [[ -z "$NEW_AD_ID" ]]; then
        # Удаляем рекламный параметр
        sed -i 's/ -P [0-9]*//g' /etc/systemd/system/$SERVICE_NAME.service
        log "Реклама отключена."
    else
        # Обновляем или добавляем параметр
        if grep -q " -P " /etc/systemd/system/$SERVICE_NAME.service; then
            sed -i "s/ -P [0-9]*/ -P $NEW_AD_ID/g" /etc/systemd/system/$SERVICE_NAME.service
        else
            sed -i "s|ExecStart=\(.*\)|ExecStart=\1 -P $NEW_AD_ID|" /etc/systemd/system/$SERVICE_NAME.service
        fi
        log "Рекламный ID обновлён: $NEW_AD_ID"
    fi
    systemctl daemon-reload
    systemctl restart $SERVICE_NAME
}

# ---------- Показать ссылки ----------
show_links() {
    if [[ -f $INSTALL_DIR/links.txt ]]; then
        cat $INSTALL_DIR/links.txt
    else
        error "Файл ссылок не найден. Установите прокси сначала."
    fi
}

# ---------- Диагностика ----------
diagnose() {
    header "ДИАГНОСТИКА"
    echo -e "${YELLOW}1. Слушающие порты:${NC}"
    ss -tlnp | grep -E "($PROXY_PORT|$STATS_PORT)" || echo "   Порты не прослушиваются."
    echo -e "\n${YELLOW}2. Статус сервиса:${NC}"
    systemctl status $SERVICE_NAME --no-pager -l | head -15
    echo -e "\n${YELLOW}3. Последние ошибки в логах:${NC}"
    journalctl -u $SERVICE_NAME --no-pager -n 10 | grep -i error || echo "   Ошибок не найдено."
}

# ---------- Деинсталляция ----------
uninstall() {
    header "ДЕИНСТАЛЛЯЦИЯ"
    read -p "Вы уверены? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        cleanup
        log "MTProxy полностью удалён."
    else
        log "Отменено."
    fi
}

# ---------- Главное меню ----------
main_menu() {
    while true; do
        clear
        status_panel
        echo ""
        echo -e "${BOLD}МЕНЮ:${NC}"
        echo "1) Установить прокси"
        echo "2) Управление сервисом (запуск/остановка)"
        echo "3) Показать ссылки для подключения"
        echo "4) Настроить рекламу"
        echo "5) Диагностика"
        echo "6) Полная деинсталляция"
        echo "0) Выход"
        read -p "Выберите пункт: " choice
        case $choice in
            1) install ;;
            2) manage_service ;;
            3) show_links ;;
            4) manage_ad ;;
            5) diagnose ;;
            6) uninstall ;;
            0) echo "Выход."; exit 0 ;;
            *) error "Неверный выбор." ;;
        esac
        echo -e "\nНажмите Enter для продолжения..."
        read
    done
}

# ---------- Запуск ----------
check_root
main_menu