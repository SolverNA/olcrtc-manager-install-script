# olcrtc-manager-install-script

Установщик [olcrtc-manager](https://github.com/BigDaddy3334/olcrtc-manager-panel) с поддержкой своего домена и готового TLS-сертификата.

## Быстрый старт

Self-signed сертификат, спросит домен/сертификат интерактивно:

```bash
curl -fsSL https://raw.githubusercontent.com/SolverNA/olcrtc-manager-install-script/refs/heads/main/install.sh | sudo bash
```

Со своим доменом и уже выпущенным Let's Encrypt сертификатом (без вопросов):

```bash
curl -fsSL https://raw.githubusercontent.com/SolverNA/olcrtc-manager-install-script/refs/heads/main/install.sh | \
  sudo PANEL_DOMAIN=example.com \
       PANEL_TLS_CERT=/etc/letsencrypt/live/example.com/fullchain.pem \
       PANEL_TLS_KEY=/etc/letsencrypt/live/example.com/privkey.pem \
       bash
```

## Переменные окружения

| Переменная         | По умолчанию      | Описание                                      |
|--------------------|-------------------|------------------------------------------------|
| `PANEL_DOMAIN`     | —                 | Домен панели (если есть)                       |
| `PANEL_TLS_CERT`   | —                 | Путь к fullchain-сертификату                   |
| `PANEL_TLS_KEY`    | —                 | Путь к приватному ключу                        |
| `PANEL_PORT`       | `8888`            | Порт панели                                    |
| `PANEL_ADDR`       | `127.0.0.1`       | Адрес прослушивания (авто `0.0.0.0` при домене) |
| `NONINTERACTIVE`   | `0`               | `1` — не задавать вопросы, брать только env-переменные |

Если `PANEL_TLS_CERT`/`PANEL_TLS_KEY` не заданы и нет терминала — генерируется self-signed сертификат.

## Что делает скрипт

1. Ставит зависимости (git, curl, openssl и т.д.) и Go.
2. Клонирует и собирает `olcrtc` и `olcrtc-manager`.
3. Создаёт конфиг и комнату по умолчанию.
4. Настраивает TLS (свой сертификат или self-signed).
5. Генерирует логин/пароль в `/etc/olcrtc-manager/panel.env`.
6. Ставит systemd-сервис `olcrtc-manager` и certbot renew-hook.

## Требования

- Ubuntu/Debian (apt-based)
- root
- Если указываете свой сертификат — он должен быть уже выпущен (например, через `certbot`) до запуска скрипта.
