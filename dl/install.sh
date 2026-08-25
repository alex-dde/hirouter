#!/bin/sh
# Установщик HiRouter для OpenWrt. Ставит движок (ядро mihomo) и агента с нуля:
# снимает прежние пакеты, вычищает старую конфигурацию движка, ставит свежие
# пакеты под архитектуру этого роутера и просит первый синк с панелью.
#
# Запуск на роутере:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/alex-dde/hirouter/main/dl/install.sh)"
#
# Версии и контрольные суммы НЕ зашиты в скрипт — он читает их из manifest.txt рядом с собой,
# поэтому новый релиз не требует правки установщика.
set -u

# Источники по порядку: основной — GitHub, запасной — своя раздача. Блокировка одного
# не должна останавливать установку.
MIRRORS="https://raw.githubusercontent.com/alex-dde/hirouter/main/dl https://up.hirouter.info/dl"
TMP=/tmp/hirouter-install
AGENT_API=http://127.0.0.1:9001

say()  { echo ">> $*"; }
die()  { echo "!! $*" >&2; exit 1; }

# fetch <url> <файл> — curl, а где его нет (голый BusyBox) — wget.
fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1" 2>/dev/null && return 0
	fi
	wget -q -O "$2" "$1" 2>/dev/null && return 0
	return 1
}

# fetch_any <имя файла> <куда> — перебирает зеркала.
fetch_any() {
	for m in $MIRRORS; do
		if fetch "$m/$1" "$2"; then
			echo "$m"
			return 0
		fi
	done
	return 1
}

check_sha() {
	# fail-closed: без контрольной суммы или без инструмента проверки НЕ ставим (раньше молча пропускали).
	[ -n "$2" ] || die "в манифесте нет контрольной суммы для $(basename "$1") — установка отменена"
	if ! command -v sha256sum >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1; opkg install coreutils-sha256sum >/dev/null 2>&1
		command -v sha256sum >/dev/null 2>&1 || die "нет sha256sum и не удалось его поставить — установка без проверки отменена"
	fi
	echo "$2  $1" | sha256sum -c - >/dev/null 2>&1
}

mkdir -p "$TMP" || die "нет доступа к /tmp"

# 1. архитектура роутера — от неё зависят оба пакета (внутри бинарь mihomo)
ARCH=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $2; }' | tail -1)
[ -n "$ARCH" ] || ARCH=$(sed -n 's/^DISTRIB_ARCH=.//p' /etc/openwrt_release 2>/dev/null | tr -d "'\"")
[ -n "$ARCH" ] || die "не удалось определить архитектуру роутера"
say "архитектура: $ARCH"

# 2. манифест: какие файлы и с какими суммами ставить для этой архитектуры
SRC=$(fetch_any manifest.txt "$TMP/manifest.txt") || die "не скачался манифест (нет связи или все зеркала недоступны)"
say "источник: $SRC"
LINE=$(grep "^$ARCH|" "$TMP/manifest.txt" | tail -1)
[ -n "$LINE" ] || die "для архитектуры $ARCH пакета нет. Сообщите модель роутера — соберём."
SS_FILE=$(echo "$LINE"  | cut -d'|' -f2); SS_SHA=$(echo "$LINE" | cut -d'|' -f3)
AG_FILE=$(echo "$LINE"  | cut -d'|' -f4); AG_SHA=$(echo "$LINE" | cut -d'|' -f5)
AG_VER=$(echo "$LINE"   | cut -d'|' -f6)
say "ставим: движок + агент $AG_VER"

# 3. качаем ОБА пакета и проверяем суммы ДО того, как что-либо ломать на роутере
fetch "$SRC/$SS_FILE" "$TMP/ss.ipk"     || fetch_any "$SS_FILE" "$TMP/ss.ipk" >/dev/null || die "не скачался $SS_FILE"
fetch "$SRC/$AG_FILE" "$TMP/agent.ipk"  || fetch_any "$AG_FILE" "$TMP/agent.ipk" >/dev/null || die "не скачался $AG_FILE"
check_sha "$TMP/ss.ipk"    "$SS_SHA" || die "контрольная сумма движка не сошлась — установка отменена"
check_sha "$TMP/agent.ipk" "$AG_SHA" || die "контрольная сумма агента не сошлась — установка отменена"
say "пакеты скачаны и проверены"

# 4. снимаем прежнее. /opt/clash удаляем целиком: старая конфигурация мешает новой —
#    агент разложит свою с нуля на первом синке.
say "убираю прежнюю установку"
/etc/init.d/hirouter stop >/dev/null 2>&1
/etc/init.d/clash stop    >/dev/null 2>&1
opkg remove hirouter          >/dev/null 2>&1
opkg remove luci-app-ssclash  >/dev/null 2>&1
rm -rf /opt/clash
# память агента о применённом конфиге: без сброса он посчитает, что менять нечего,
# и оставит роутер без конфигурации (проверено на стенде 19.08.2026).
rm -f /etc/hirouter/state.json

# 5. установка
opkg update >/dev/null 2>&1

# Зависимости. На старых/минимальных прошивках их часто нет, и без них агент не встаёт
# (agent.ipk тянет curl/ca-bundle/luci-compat, ca-bundle нужен ещё и для HTTPS).
# Фид OpenWrt в RU-сетях ЧАСТО флейкует — обрыв одного файла (wget err 4), особенно luci-фида,
# где живёт luci-compat. Поэтому ставим с РЕТРАЯМИ: между попытками освежаем список пакетов —
# транзиентный обрыв уходит на следующей попытке (проверено: со второго прогона встаёт).
# На отдельном пакете не падаем — реальным гейтом будет установка самих пакетов ниже.
say "проверяю зависимости"
opkg update >/dev/null 2>&1
# kmod-nft-tproxy — модуль ядра netfilter TPROXY. БЕЗ него clash-rules строит nft-правило
# `... tproxy ip to 127.0.0.1:7894`, оно молча не применяется → трафик не заворачивается в
# движок → «интернет есть, а через VPN — нет» (диагноз @sitzim: подтянулся с podkop и вылечил).
# Вложить нельзя (арх-зависимый kmod), поэтому только с ретраями из фида.
for dep in ca-bundle curl luci-compat kmod-nft-tproxy; do
	if opkg list-installed 2>/dev/null | grep -q "^$dep "; then
		continue
	fi
	ok=""
	for try in 1 2 3; do
		if opkg install "$dep" >/dev/null 2>&1; then ok=1; break; fi
		if [ "$try" -lt 3 ]; then say "  $dep: фид моргнул, повтор $try/3…"; opkg update >/dev/null 2>&1; fi
	done
	# Фолбэк МИМО фида — только если фид так и не отдал. Кладём лишь ca-bundle: он
	# самодостаточный (arch all, deps=libc). luci-compat так нельзя — его дерево это 31
	# арх-зависимый пакет (весь LuCI/lua-стек), в раздачу не вложить.
	if [ -z "$ok" ] && [ "$dep" = "ca-bundle" ]; then
		if fetch_any "ca-bundle.ipk" "$TMP/ca-bundle.ipk" >/dev/null; then
			opkg install "$TMP/ca-bundle.ipk" >/dev/null 2>&1 && { ok=1; say "  ca-bundle: фид недоступен — поставил из раздачи"; }
		fi
	fi
	[ -n "$ok" ] || say "  $dep не встал — продолжаю (проверю на установке агента)"
done

say "ставлю движок"
opkg install "$TMP/ss.ipk"    >/dev/null 2>&1 || die "не установился движок (проверьте место на флеше: df -h)"
say "ставлю агента"
opkg install "$TMP/agent.ipk" >/dev/null 2>&1 || die "не установился агент. Обычно это нехватка зависимостей или нет связи с фидом — выполните: opkg update && opkg install curl ca-bundle luci-compat, затем повторите установку."

# 6. первый синк
say "запрашиваю конфигурацию у панели"
sleep 25
TOKEN=$(cat /etc/hirouter/local.token 2>/dev/null)
if [ -n "$TOKEN" ]; then
	curl -s -m 120 -X POST -H "X-Local-Token: $TOKEN" "$AGENT_API/sync/cfg" >/dev/null 2>&1
fi
sleep 15
ST=$(curl -s -m 20 -H "X-Local-Token: $TOKEN" "$AGENT_API/status" 2>/dev/null)
VER=$(echo "$ST" | tr ',' '\n' | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)
RUN=$(echo "$ST" | tr ',' '\n' | grep -c '"clash_running":true')
PRX=$(echo "$ST" | tr ',' '\n' | sed -n 's/.*"proxies":\([0-9]*\).*/\1/p' | head -1)
SER=$(echo "$ST" | tr ',' '\n' | sed -n 's/.*"serial":"\([^"]*\)".*/\1/p' | head -1)

echo
echo "──────────────────────────────────────────────"
echo " HiRouter установлен"
echo " серийный номер : ${SER:-неизвестен}"
echo " версия агента  : ${VER:-нет ответа}"
echo " VPN запущен    : $([ "$RUN" = "1" ] && echo да || echo нет)"
echo " серверов       : ${PRX:-0}"
echo "──────────────────────────────────────────────"
if [ "${PRX:-0}" = "0" ]; then
	echo " Серверов пока нет — это нормально для нового роутера:"
	echo " подтвердите его в панели, дальше конфигурация приедет сама (до 5 минут)."
fi
