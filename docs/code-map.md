# Карта кода tgwsproxy

Документ описывает каждый файл репозитория: за что он отвечает, какие у него
границы и что менять при доработке. Это не API-справочник — точные сигнатуры
смотрите в исходниках и в `docs/architecture.md`.

## Правила слоёв

- `lib/` — Flutter UI и Android-оболочка. Не содержит MTProto-логики.
- `packages/tg_proxy_core/` — чистый Dart-движок. Не импортирует Flutter.
- `android/` — Kotlin-сервис, каналы, хранение, уведомления, tile, boot.
- `docs/` — архитектура и эта карта.

Направление зависимостей: `flutter app -> platform channels -> Kotlin service
-> headless FlutterEngine -> tg_proxy_core`. Обратных импортов быть не должно.

---

## Корень репозитория

| Файл | Ответственность |
|---|---|
| `pubspec.yaml` | Flutter-приложение, зависимости UI, Drift, path-пакет `tg_proxy_core`, версия и Android-only настройки. |
| `pubspec.lock` | Зафиксированные версии зависимостей. Генерируется, руками не править. |
| `analysis_options.yaml` | Линтеры Flutter-приложения. |
| `build.yaml` | Ограничивает `drift_dev` одним файлом БД, чтобы codegen не падал на analyzer/Dart 3.14. |
| `Makefile` | Короткие команды: `gen`, `run`, `test`, `analyze`, `format`, `apk`, `check`, `core-test`. |
| `README.md` | Статус этапов, запуск, структура. |
| `LICENSE` | MIT. |
| `NOTICE` | Атрибуция Flowseal/AndMTProto (MIT) и исторического amurcanov (GPLv3, код не используется). |
| `.github/workflows/ci.yml` | CI: format, analyze, Flutter tests, `dart pub get` + core tests, debug APK. |
| `.gitignore` | Игнорирует build, `.dart_tool`, секреты, `.opencode`. |
| `tgwsproxy.iml` | Метаданные IDE; не влияет на сборку. |
| `docs/architecture.md` | Архитектура v1.1: решения, контракты, паритет, roadmap. |
| `docs/code-map.md` | Этот документ. |

---

## Flutter-приложение (`lib/`)

| Файл | Ответственность |
|---|---|
| `lib/main.dart` | Точка входа UI: portrait, app support dir, открытие Drift `app.db`, `AppModel.init()`, `runApp` с `ChangeNotifierProvider`. Не запускает прокси. |
| `lib/proxy_main.dart` | `runProxyEngine()` — поднимает `ProxyEngine` и engine-channel в headless-изоляте. Сам `proxyMain` объявлен в `lib/main.dart`, потому что Flutter стабильно резолвит entrypoint только из main-библиотеки. Не вызывает `runApp`. |
| `lib/core/application.dart` | Корневой `MaterialApp.router`: темы, locale `ru`, делегаты material/cupertino, `GoRouter`, `ThemeMode` из `AppModel`. |
| `lib/core/model/app_model.dart` | Глобальное состояние UI: `AppDatabase`, тема, загрузка/сохранение `theme_mode`, закрытие БД в `dispose`. |
| `lib/core/db/app_database.dart` | Drift-БД `app.db`, таблица `app_preferences(key,value)`, `read/write`; только UI-настройки (тема, onboarding, last tab). Прокси-настройки здесь не хранятся. |
| `lib/core/db/app_database.g.dart` | Сгенерированный Drift-код. Не редактировать; пересобирать `make gen`. |
| `lib/app_router.dart` | `GoRouter` + `StatefulShellRoute.indexedStack`, 4 ветки: `/connection`, `/settings`, `/logs`, `/info`. |
| `lib/core/ui/main_shell.dart` | `NavigationBar` с четырьмя разделами и `NavigationShell`. |
| `lib/core/theme/app_theme.dart` | Material 3 тема, seed `0xFF2AABEE`, светлая/тёмная схемы, карточки, navigation bar. |
| `lib/features/connection/connection_page.dart` | Экран подключения: большая кнопка старт/стоп, статус, статистика, ошибка, шаги подключения. |
| `lib/features/connection/connection_wm.dart` | ViewModel подключения: слушает `ProxyRepository`, отображает `ProxySnapshot` в `ProxyStatus`, адрес, маршрут, трафик; `toggle()` вызывает start/stop. |
| `lib/features/settings/settings_page.dart` | Настройки: тема, autostart, проверка обновлений; транспортные разделы — Stage 6. |
| `lib/features/settings/settings_wm.dart` | Сохранение UI-настроек в Drift; прокси-настройки — через Kotlin DataStore (UI — Stage 6). |
| `lib/features/logs/logs_page.dart` | Экран логов: фильтры, пустое состояние, копирование/шеринг (заглушки, Stage 6). |
| `lib/features/logs/logs_wm.dart` | Модель логов и фильтров; на Stage 6 подключается к EventChannel/Kotlin `LogRepository`. |
| `lib/features/info/info_page.dart` | Версия, лицензия MIT, ссылки на источники, приватность. |
| `test/widget_test.dart` | Widget-тест idle-состояния экрана подключения. |

---

## Dart-ядро (`packages/tg_proxy_core/lib/`)

### Точка входа и общие данные

| Файл | Ответственность |
|---|---|
| `tg_proxy_core.dart` | Публичный barrel-файл пакета: экспортирует config, constants, crypto, handshake, splitter, FakeTLS, Bot API, transport, pools, server, bridge, stats. |
| `src/version.dart` | `coreVersion` — версия ядра для диагностики и engine-handshake. |
| `src/constants.dart` | Все протокольные константы: длины handshake, теги EF/EE/DD, DC IP (обычные/тестовые), `/apiws`, `/apiws_test`, `wsDomains`. Единственное место, где меняются протокольные числа. |
| `src/config/proxy_config.dart` | `ProxyConfig`: порт, host, secret, DC redirects, pool, CF domains, FakeTLS, no_secure, proxy protocol, force test DC. `bufferSize` — только совместимость. `redirectIp/fallbackIp`. |
| `src/stats/proxy_stats.dart` | Мутабельные счётчики `ProxyStats` и иммутабельный `StatsSnapshot.toJson()` для канала/уведомления. |

### Криптография и MTProto

| Файл | Ответственность |
|---|---|
| `src/crypto/aes_ctr.dart` | AES-256-CTR на PointyCastle: `process`, `skip` (пропуск keystream — часть протокола, не оптимизация), валидация key/iv. |
| `src/crypto/hex.dart` | `bytesToHex` / `hexToBytes` для секрета и тестовых векторов. |
| `src/mtproto/handshake.dart` | `tryHandshake` (64-байтный obfs2 init, SHA256(prekey+secret), proto tag, DC int16), `generateRelayInit` (случайные 64 байта с запрещёнными префиксами + зашифрованный хвост), `buildCryptoContext` (4 AES-CTR потока, skip 64 только там, где нужно), `protoTagToInt`. |
| `src/mtproto/splitter.dart` | `MsgSplitter`: параллельно хранит ciphertext и plaintext, режет abridged (0x7F/0xFF + 3 байта LE ×4) и intermediate/padded (4 байта LE & 0x7FFFFFFF), отключается при ошибке и пропускает остаток, `flush()` для хвоста. |

### FakeTLS и Bot API

| Файл | Ответственность |
|---|---|
| `src/faketls/fake_tls.dart` | Маскировка под TLS 1.3: разбор ClientHello, HMAC-SHA256, replay-cache, timestamp ±120 с, сборка ServerHello+CCS+ApplicationData, выбор X25519/hybrid, `FakeTlsStream` (чтение/запись TLS-записей, CCS), `wrapTlsRecords`, 301 на masking-домен. |
| `src/botapi/bot_api_proxy.dart` | Локальный HTTP CONNECT-прокси `127.0.0.1:8081`: allowlist `api.telegram.org`, 405/403/502, после 200 — сырой relay через инжектированный connector. Без root, без AES. |

### Транспорт

| Файл | Ответственность |
|---|---|
| `src/transport/proxy_transport.dart` | Интерфейс `ProxyTransport` (send/receive/close/isClosed) и `TcpTransport` поверх `Socket` с TCP_NODELAY. |
| `src/transport/raw_websocket.dart` | Собственный WebSocket-клиент поверх TCP/`SecureSocket`: HTTP Upgrade, `Sec-WebSocket-Protocol: binary`, маскирование клиентских кадров, fragmentation, ping/pong, close, лимит 16 МБ, flush для backpressure. Не использует `dart:io WebSocket`. |
| `src/transport/cf_domains.dart` | Встроенный обфусцированный список 20 CF-доменов, декодирование, нормализация/дедуп, `CfDomainBalancer` (активный домен на DC), `CfDomainManager` (refresh раз в час, минимум 3 валидных). |
| `src/transport/ws_pool.dart` | Пул прямых Telegram WS: ключ `(dc, media, test)`, reuse 120 с, warmup, refill с backoff, `defaultWsConnector` (выбирает `wsDomains`, `/apiws` или `/apiws_test`). |
| `src/transport/cf_worker_pool.dart` | Пул CF Worker: `/apiws?dst=...&dc=...`, reuse 100 с, лимит 1 на DC, cooldown 429. |
| `src/transport/tcp_fallback.dart` | Прямой TCP к DC:443 с экспоненциальным backoff 30 с…1 ч и защитой от параллельных попыток. |
| `src/transport/transport_router.dart` | `ConnectedTransport` и порядок маршрутов: direct WS → CF worker → CF proxy → TCP; обновляет stats.ws/cf/tcpFallback; warmup/dispose. |

### Сервер и мост

| Файл | Ответственность |
|---|---|
| `src/proxy/client_transport.dart` | Буферизованный клиентский транспорт: `readExact/readByte/readLine`, pending-буфер, таймауты; используется до и после `FakeTlsStream`. |
| `src/proxy/bridge.dart` | `runMtProtoBridge`: два направления, client decrypt → telegram encrypt → optional splitter → remote; remote decrypt → client encrypt; статистика байт, splitter tail, закрытие обеих сторон. |
| `src/proxy/proxy_server.dart` | `ProxyServer`: bind `127.0.0.1`, accept, optional PROXY protocol, FakeTLS/301, 64-байтный handshake, test/media DC, relay init, router/connector, splitter для ws/cf, запуск bridge, stop/active clients, stats. |

---

## Тесты ядра (`packages/tg_proxy_core/test/`)

| Файл | Что проверяет |
|---|---|
| `version_test.dart` | Версия пакета не пустая. |
| `crypto_test.dart` | NIST AES-256-CTR вектор, `skip(64)`, инкрементальность. |
| `handshake_test.dart` | Python-векторы handshake abridged/media, плохой тег, длины, relay init, 4 потока контекста. |
| `splitter_test.dart` | Abridged short/long, intermediate/padded, два пакета, partial+flush, отключение при ошибке. |
| `transport/raw_websocket_test.dart` | Локальный TCP-сервер: 101 upgrade, маскированные кадры, fragmentation, ping/pong, close, 403. |
| `transport/cf_domains_test.dart` | Декодирование домена, 20 уникальных, нормализация, balancer, min 3, user domains. |
| `transport/pools_test.dart` | WS pool reuse/stale, CF worker path/429, TCP backoff, router order. |
| `faketls/fake_tls_test.dart` | ClientHello HMAC/replay/time, ServerHello, hybrid/X25519, FakeTlsStream, 16384 split. |
| `botapi/bot_api_test.dart` | CONNECT tunnel, 403/405/502, сохранение leftover. |
| `proxy/relay_server_test.dart` | Реальный loopback: handshake, relay init, оба направления re-encrypt, splitter, bad handshake, stop. |

---

## Android и сборочные файлы

| Файл | Ответственность |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | Разрешения (INTERNET, network state, WAKE_LOCK, FGS specialUse, notifications, boot, install packages), `MainActivity singleTask`, `ProxyService` (specialUse, stopWithTask=false), `ProxyTileService`, `BootReceiver`, queries Telegram. |
| `android/app/build.gradle.kts` | `applicationId com.example.tgwsproxy`, SDK 29/36/37, Java 17, release под debug-ключом (временно), `useLegacyPackaging=false` для 16 KB. |
| `android/build.gradle.kts`, `settings.gradle.kts` | Gradle-плагины и модули. |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Host Flutter UI; регистрирует `ProxyBridge` и освобождает его при уничтожении Activity. |
| `.../core/ProxyBridge.kt` | MethodChannel `/proxy` и EventChannel `/proxy_events`: bootstrap, start/stop/restart, настройки, секрет, ссылка, диагностика. |
| `.../data/ProxySettings.kt` | Канонические настройки прокси в DataStore; `toEngineJson()` для headless-ядра. |
| `.../data/SecretStore.kt` | 16-байтовый секрет: генерация, AES-GCM через Android Keystore, хранение Base64. |
| `.../data/ProxyStateRepository.kt` | `StateFlow` состояния и статистики; единственный источник для UI и уведомления. |
| `.../service/ProxyEngineHost.kt` | `FlutterEngineGroup` + headless `proxyMain`, канал `/engine`, ready/start/stop/stats. |
| `.../service/ProxyService.kt` | Foreground service specialUse, уведомление, wakelock, владение `ProxyEngineHost`. |
| `.../service/ProxyController.kt` | Intent-обёртки start/stop/restart для Activity, tile и boot. |
| `.../service/ProxyTileService.kt` | Quick Settings tile: старт/стоп по состоянию. |
| `.../service/BootReceiver.kt` | Автозапуск после загрузки, если включён `autoStart`. |
| `lib/core/proxy/domain/proxy_backend.dart` | Контракт бэкенда прокси: события, bootstrap, start/stop/settings, секрет, диагностика. |
| `lib/core/proxy/data/channel_proxy_backend.dart` | MethodChannel/EventChannel для Android и iOS. |
| `lib/core/proxy/data/mac_proxy_engine.dart` | In-process Dart-ядро для macOS. |
| `lib/core/proxy/proxy_repository.dart` | Фасад состояния для UI: выбирает бэкенд, хранит state/settings/logs, реагирует на события `{type: menu}`. |
| `android/app/src/main/res/...` | Иконки, стили, строки уведомлений; канал уведомлений создаётся в `ProxyService`. |
| `scripts/check_16kb.sh` | Проверка выравнивания native-библиотек Flutter под 16 KB pages. |

---

## Что менять при типовых задачах

- Новый протокольный тег/порт/DC — только `src/constants.dart` + тесты.
- Новый маршрут — `transport_router.dart`, затем тест в `pools_test.dart`.
- Новое поле настроек — `proxy_config.dart` (ядро), `data/ProxySettings.kt` (DataStore) и JSON-схема в `docs/architecture.md`; UI читает через `ProxyRepository`.
- Новый экран — `lib/features/<feature>/`, ветка в `app_router.dart`, provider в модуле.
- Ошибка handshake/bridge — `proxy_server.dart`, `bridge.dart`, `relay_server_test.dart`.
- Ошибка FakeTLS — `faketls/fake_tls.dart` + `fake_tls_test.dart` (там же эталонные ClientHello).
- Ошибка WebSocket/CF — `transport/raw_websocket.dart`, `cf_domains.dart`, `ws_pool.dart`, тесты транспорта.

## Границы, которые нельзя нарушать

- Ядро не импортирует `package:flutter/*` и не знает про Android.
- UI не вызывает `dart:io`-прокси напрямую; только через `ProxyBridge`/`ProxyRepository`. Прокси-настройки не дублируются в Drift.
- Секрет не пишется в логи и не хранится в Drift.
- `bufferSize` не применяется в Dart; не добавляйте фейковую поддержку.
- TLS проверяется; никакого `onBadCertificate: (_) => true` в основном пути.
- H2-медиа — отдельная фаза; не смешивать с WS-путём.
