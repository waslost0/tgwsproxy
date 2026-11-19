# Архитектура tgwsproxy

**Версия:** 1.2 · **Дата:** 2026-11-18 · **Статус:** Android MVP реализован; этап 6 (паритет и надёжность) в работе; iOS — отдельный трек

Android-приложение на Flutter: локальный MTProto-прокси для Telegram с транспортом через Cloudflare Worker / WebSocket и прямым TCP-fallback. UI и настройки — по образцу рабочего `AndMTProto`, недостающие возможности — из десктопного `tg-ws-proxy`.

> **Изменение 1.1.** Ядро прокси перенесено с Python/Chaquopy на **чистый Dart**. Python-код рабочего `AndMTProto` (MIT) остаётся источником проверенной логики и констант для порта; в APK ни Python, ни нативного ядра нет. Kotlin-сервис остаётся владельцем Android-жизненного цикла и запускает headless `FlutterEngine` с Dart-ядром.
>
> **Изменение 1.2.** Добавлен фактический статус реализации (§21), обновлены матрица паритета, дорожная карта и план iOS. Разделы 6–17 описывают целевую архитектуру; если они расходятся с §21, приоритет у §21.

---

## 1. Коротко

| Вопрос | Решение |
|---|---|
| Состояние | Android: ядро, сервис и основной UI работают; 59 тестов ядра; остались паритет настроек, сетевой watchdog, логи/обновления и H2 (§21) |
| Ядро | Чистый Dart-движок `packages/tg_proxy_core` — порт Python-ядра Flowseal из `AndMTProto`; Python и нативного ядра в APK нет |
| Лицензия проекта | **MIT** (порт MIT-кода; сохраняем copyright Flowseal) |
| UI | `base-flutter`: MVVM + provider + go_router + Drift (без Elementary) |
| Владелец жизненного цикла | Kotlin foreground service; Dart-ядро живёт в headless `FlutterEngine` сервиса |
| Связь UI Flutter ↔ Android | MethodChannel + EventChannel, JSON-строки |
| Связь Kotlin ↔ Dart-ядро | MethodChannel `.../engine` внутри headless engine, JSON |
| Хранилище настроек | Kotlin DataStore — единственный источник истины; Drift — только UI-состояние; секрет — Android Keystore |
| Bot API | Ядро и запуск `127.0.0.1:8081` готовы; UI и выключение по умолчанию — этап 6 |
| minSdk / targetSdk | 29 / 36, compileSdk из base-flutter (37) |
| Package id | `com.example.tgwsproxy` — временный, заменить до релиза |
| Платформы | Android реализован. iOS — отдельный личный трек через Network Extension (§21); web/desktop — вне scope |

---

## 2. Цели и не-цели

### Цели

1. Повторить и продолжить функциональность рабочего `AndMTProto`: foreground service, уведомление, QS tile, автозапуск, лог-вьюер, DC-настройки, темы, обновления, auto-port, network restart, stall/TLS-детектор.
2. Закрыть разрыв с десктопом: FakeTLS, CF worker domains, WS keepalive, proxy protocol, force test DC, файловые логи, импорт/экспорт конфига, экран статистики, Bot API. `buffer size` переносится как поле совместимости, но не применяется — `dart:io` не даёт менять SO_RCVBUF/SO_SNDBUF (см. ADR-13).
3. Сохранить архитектуру и конвенции `base-flutter` (MVVM, модули, типизированные роуты), убрав всё лишнее.
4. Стабильность: прокси переживает сворачивание приложения, убийство UI-процесса, перезагрузку, смену сети.

### Не-цели

- iOS в текущем Android-приложении; iOS вынесен в отдельный трек (§21), web/desktop — вне scope.
- Трей, portable mode, CLI-флаги.
- Прозрачный перехват всего трафика через `VpnService` (конфликтует с прокси Telegram и требует отдельной модели разрешений).
- Правка `/etc/hosts` и прослушивание `:443` (нужен root; заменено на Bot API HTTP-прокси).
- Публикация в Google Play (package id временный; политика по прокси-приложениям не прорабатывалась).
- Аналитика, Crashlytics, push, backend, авторизация, карты, AppMetrica.
- Миграция настроек из старого `tg-ws-proxy-android` (формата экспорта там нет).

---

## 3. Исходные проекты и что берём

### 3.1. `Flowseal/tg-ws-proxy` (десктоп, MIT)

Берём поведение и состав функций:

- цепочка Telegram → локальный MTProto → WSS через CF Worker/домен → DC; fallback на прямой TCP;
- конфиг: host, port, secret, dc_ip, verbose, check_updates, log_max_mb, buf_kb, pool_size, cfproxy, cfproxy_user_domain, cfproxy_worker_domain, force_test_dc, ws_keepalive_interval, bot_api, language, autostart, appearance;
- пул CF-доменов: встроенный обфусцированный список + обновление раз в час из GitHub, минимум 3 валидных домена;
- FakeTLS (`ee`-секрет), proxy protocol, тестовые DC;
- Bot API: прозрачный туннель `api.telegram.org` через CF Worker `/apiws?dst=api.telegram.org` (на десктопе — через hosts и `127.0.0.2:443`).

### 3.2. `oruviyex18/AndMTProto` — текущий рабочий Android-форк (MIT)

Главный источник функциональности. Внутри — Python-ядро Flowseal, запущенное на телефоне через Chaquopy; UI — Kotlin + Compose. Лицензия MIT, copyright Flowseal.

Берём:

- Python-ядро `proxy/` (4644 LOC): config, utils, `tg_ws_proxy`, bridge, pool, raw_websocket, fake_tls, cf_h2, h2_transport, balancer, stats, event_loop, network_debug, `_aes`;
- Kotlin-слой: `ProxyService`, `ProxyCore`, `ProxyTileService`, `BootReceiver`, `ConnectionWatch`, `StallDetector`, `ProxySettings`, `UpdateCheckJob`, `SystemIntents`;
- UX: большая кнопка старта, статус/маршруты/статистика, hint-карточки, настройки с секциями, лог-шит, QR/ссылка, apply-in-Telegram, динамические цвета, палитры, экспериментальные DC (5, 203, media), интервалы проверки обновлений;
- проверенные константы: порт 1443, пул 4, буферы 256 КБ (см. ADR-13), таймауты, `/apiws`, `/apiws_test`, Cooldown 429, reuse 120 с, DC-списки и тестовые DC;
- сетевые сценарии: auto-port при занятом 1443, рестарт при смене сети, stall detector 60 с, TLS-проба CF и авто-включение `no_secure`, watchdog, ротация логов с редактированием секрета.

Что меняем:

- Python/Chaquopy → **чистый Dart-порт** `packages/tg_proxy_core`; Python в APK не остаётся;
- Compose → Flutter-UI на base-flutter;
- SharedPreferences → Kotlin DataStore (канонические настройки) + Drift (UI-состояние);
- добавляем Bot API (локальный HTTP CONNECT) и импорт/экспорт конфига;
- H2-медиа — второй этап: сначала WS pool + CF proxy + CF worker + TCP fallback, затем порт `cf_h2`/`h2_transport`;
- `bufferSizeKb` остаётся в схеме, но не применяется (ADR-13);
- `amurcanov/tg-ws-proxy-android` (GPLv3, не работает) — только исторический UX-референс, код не берём.

### 3.3. `base-flutter`

Берём: `Application`, `AppModel`, модули, `BasePage/BaseWM`, `BaseListPage/BaseInfinityScrollWM`, typed go_router, `ThemeBuilder`, Talker-логгер, диалоги/снэкбары, CI-каркас. `KeyValueStorage` заменяем на Drift.

Вырезаем: Firebase/HMS, AppMetrica, MapKit, backend API, auth/profile, push, PIN, новости/каталог/заказы, image_picker, video/audio/pdf, мобильный сканер, Crashlytics.

> **Права на шаблон.** `base-flutter` — внутренний шаблон WTS. Перед публикацией кода под MIT нужно подтвердить право на распространение производной работы. Это организационный риск, а не технический.

---

## 4. Ключевые решения (ADR)

| # | Решение | Почему | Последствия |
|---|---|---|---|
| ADR-1 | Перенести ядро на Dart (порт MIT Python) | Требование заказчика; один язык, нет JNI/Chaquopy, проще отладка и сборка | Порт ~4.6k строк; риск производительности AES-CTR и TLS-кривых; проект остаётся MIT |
| ADR-2 | Жизненный цикл прокси — в Kotlin foreground service | Запуск с boot/tile без Flutter; UI может быть уничтожен | Flutter — только пульт; все настройки доступны сервису |
| ADR-3 | Настройки в Kotlin DataStore, не в Drift | Сервис читает их без Flutter; один источник истины | Flutter кэширует в памяти, пишет через канал; Drift — только onboarding/scroll |
| ADR-4 | Kotlin ↔ Dart через MethodChannel в headless engine | Нет JNI и нативных библиотек; JSON проще тестировать | Нужен ready-handshake и watchdog; канал не для тяжёлого трафика |
| ADR-5 | Один JSON-конфиг на старт движка | Порядок настроек не размазан по Kotlin; проще тестировать | Dart-модель `EngineConfig` + повторная валидация |
| ADR-6 | Bot API — локальный HTTP CONNECT-прокси | Работает без root; не нужен VPN | Клиент бота надо настроить на `127.0.0.1:8081`; это не прозрачно для всех приложений |
| ADR-7 | Два FlutterEngine в одном процессе: UI и headless-сервис | Headless engine не может показывать UI; сервис стартует без Activity | +память на второй engine; состояние через Kotlin `StateFlow`; смягчаем `FlutterEngineGroup` |
| ADR-8 | Только Android, база урезается | Меньше платформенного кода и зависимостей | Нет iOS/web; при необходимости — отдельный трек |
| ADR-9 | Никакой аналитики и сетевых SDK | Приложение про приватность; меньше разрешений | Диагностика только локальные логи/отчёт |
| ADR-10 | minSdk 29 | Совпадает с base-flutter; FGS, notification channels, Keystore | Отсекаем Android 8–9 (небольшая доля) |
| ADR-11 | Свой raw WebSocket поверх `SecureSocket`, не `dart:io WebSocket` | Нужны SNI, управляемый TLS, маскирование, ping/pong и backpressure | Больше кода; покрываем тестами кадров и handshake |
| ADR-12 | Сначала чистый Dart AES-CTR, FFI — только по результату бенчмарка | Логика остаётся в Dart; нет нативной сборки | Если <10 МБ/с на целевом ARM — добавляем узкий FFI-примитив, ADR пересматривается |
| ADR-13 | `bufferSizeKb` — только поле совместимости | `dart:io` не даёт SO_RCVBUF/SO_SNDBUF; менять размер буфера ядра нельзя | В UI скрыто/помечено «не поддерживается»; импорт не ломается |
| ADR-14 | TLS-сертификаты проверяются по умолчанию, без NoVerify | Так работает рабочий AndMTProto: certifi + check_hostname; MTProto всё равно E2E-шифрован | Нет fronting-обхода; при DPI остаётся `no_secure` (порт 80) и смена CF-домена |
| ADR-15 | H2-медиа — отдельный этап после WS/MVP | `cf_h2` — 998 строк мультиплексирования, replay/backpressure; высокий риск для первого релиза | MVP без H2; медиа идёт через WS/CF; H2 включается флагом после порта |

---

## 5. Архитектура целиком

```
┌────────────────────────────── Android process ──────────────────────────────┐
│                                                                             │
│  ┌──────────────────────────────┐      ┌──────────────────────────────────┐  │
│  │ Flutter UI engine            │      │ ProxyService (Kotlin, FGS)      │  │
│  │ UI isolate                   │      │ notification · wakelock · tile  │  │
│  │ Connection/Settings/Logs/Info│      │ BootReceiver · DataStore        │  │
│  │ MVVM · provider · go_router  │      │ Keystore · StateFlow            │  │
│  └──────────────┬───────────────┘      │        │ MethodChannel          │  │
│                 │ MethodChannel        │        │ .../engine              │  │
│                 │ .../proxy            │        ▼                        │  │
│                 ▼                      │  Headless FlutterEngine          │  │
│          ProxyBridge (Kotlin) ◄────────┤  proxyMain (Dart isolate)       │  │
│          ProxyController               │  Dart proxy core                │  │
│                                        │  server · mtproto · crypto      │  │
│                                        │  ws/tls · pool · cfproxy        │  │
│                                        │  faketls · botapi · stats       │  │
│                                        └───────┬───────────────┬─────────┘  │
└────────────────────────────────────────────────┼───────────────┼────────────┘
                                                 │ TCP 1443      │ WSS
                                                 │ HTTP 8081     │
                              Telegram-клиент ──►┘               ▼
                              Bot-клиент      ──►        CF Worker / domain
                                                          /apiws, /apiws_test
                                                          /apiws?dst=api.telegram.org
                                                                  │ TCP
                                                                  ▼
                                                        Telegram DC / api.telegram.org
                              Dart core ──TCP fallback───────────────────────► DC
```

Два engine в одном процессе: UI engine монтирует Activity и рисует интерфейс; headless engine сервиса не вызывает `runApp`, не регистрирует плагины и работает только с `dart:io` + MethodChannel. Состояние между ними — через Kotlin `ProxyStateRepository` (`StateFlow`), а не через общую память Dart-изолятов.

### Границы ответственности

| Слой | Отвечает | Не отвечает |
|---|---|---|
| Flutter UI | отображение, ввод, валидация форм, темы, локализация, update-check UI | запуск/остановка сервиса, хранение секрета, работа в фоне |
| Kotlin service | lifecycle, FGS, notification, wake lock, DataStore, Keystore, boot/tile, watchdog, stats-агрегация | бизнес-логика MTProto/WS |
| Dart core | MTProto obfuscation, AES-CTR, WS/TLS, пулы, CF-балансер, FakeTLS, Bot API relay, статистика | Android UI, разрешения, хранение настроек |

---

## 6. Структура репозитория

```
tgwsproxy/
├── android/
│   └── app/
│       ├── build.gradle.kts
│       └── src/main/
│           ├── AndroidManifest.xml
│           ├── kotlin/com/example/tgwsproxy/
│           │   ├── MainActivity.kt
│           │   ├── TgWsProxyApp.kt
│           │   ├── core/
│           │   │   ├── ProxyBridge.kt        # UI Method/EventChannel
│           │   │   ├── EngineChannel.kt      # service ↔ headless Dart
│           │   │   ├── ProxyConfig.kt        # JSON-модель + валидация
│           │   │   └── ProxyErrors.kt
│           │   ├── data/
│           │   │   ├── SettingsStore.kt      # DataStore
│           │   │   ├── SecretStore.kt        # Keystore + DataStore
│           │   │   ├── ProxyStateRepository.kt
│           │   │   └── LogRepository.kt
│           │   ├── service/
│           │   │   ├── ProxyService.kt
│           │   │   ├── ProxyEngineHost.kt    # headless FlutterEngine
│           │   │   ├── ProxyController.kt
│           │   │   ├── ConnectionWatch.kt    # сеть, stall detector, TLS probe
│           │   │   ├── ProxyNotification.kt
│           │   │   ├── ProxyTileService.kt
│           │   │   └── BootReceiver.kt
│           │   └── ui/
│           │       ├── TelegramLauncher.kt
│           │       ├── UpdateInstaller.kt
│           │       └── UpdateCheckJob.kt
│           └── res/{values,values-ru,drawable,xml}/
├── packages/
│   └── tg_proxy_core/                  # чистый Dart, без Flutter
│       ├── pubspec.yaml
│       ├── lib/tg_proxy_core.dart
│       ├── lib/src/config/{config,constants}.dart
│       ├── lib/src/crypto/{aes_ctr,hash}.dart
│       ├── lib/src/mtproto/{handshake,splitter,protocol}.dart
│       ├── lib/src/transport/{raw_websocket,tls,ws_pool,cf_worker,tcp_fallback}.dart
│       ├── lib/src/faketls/{server,records}.dart
│       ├── lib/src/cfproxy/{domains,balancer,probe}.dart
│       ├── lib/src/h2/{pool,transport}.dart   # этап 2
│       ├── lib/src/botapi/proxy.dart
│       ├── lib/src/proxy/{server,bridge,router,client_handler}.dart
│       ├── lib/src/{stats,logging,network_debug}.dart
│       ├── test/...
│       └── benchmark/aes_ctr_benchmark.dart
├── lib/
│   ├── main.dart
│   ├── proxy_main.dart                 # entrypoint headless-сервиса
│   ├── runner.dart
│   ├── core/
│   │   ├── application.dart
│   │   ├── db/{app_database.dart,app_database.g.dart}
│   │   ├── model/app/{app_model.dart,config.dart,module/base_app_module.dart}
│   │   ├── proxy/{proxy_bridge.dart,proxy_models.dart,proxy_repository.dart}
│   │   ├── router/{app_router.dart,app_routes.dart,app_routes.g.dart}
│   │   ├── theme/{theme_builder.dart,app_colors.dart}
│   │   ├── page/{base_page.dart,base_wm.dart}
│   │   ├── view/...
│   │   └── debug/logger.dart
│   ├── features/
│   │   ├── connection/
│   │   ├── settings/
│   │   ├── logs/
│   │   └── info/
│   └── l10n/{intl_ru.arb,intl_en.arb}
├── assets/help/{ru,en}/*.md
├── docs/architecture.md
├── scripts/check_16kb.sh
├── .github/workflows/{ci.yml,release.yml}
├── Makefile
├── LICENSE                  # MIT
├── NOTICE                   # Flowseal copyright, MIT
└── pubspec.yaml             # name: tgwsproxy
```

Платформенные каталоги `ios/`, `web/`, `macos/`, `linux/`, `windows/` из base-flutter удаляются.

---

## 7. Flutter-слой

### 7.1. Что оставляем в base-flutter

| Компонент | Судьба |
|---|---|
| `Application` / `ApplicationWM` | Оставить, вычистить auth/profile/preload, оставить bootstrap прокси |
| `AppModel` | Оставить `Config`, `EventBus`, `NavigationModel`, `ThemeBuilder`, `packageInfo`, `AppDatabase` (Drift); добавить репозитории прокси |
| Модули | Удалить все, добавить `ProxyModule` |
| `BasePage/BaseWM`, `BaseListPage/BaseInfinityScrollWM` | Оставить |
| `app_router.dart` | Переписать: 4 ветки shell, без auth/PIN |
| `ThemeBuilder` | Оставить, добавить dynamic color и палитры |
| `WTSLogger` | Переименовать в `AppLogger`, оставить Talker + консоль, убрать Crashlytics |
| `SecureStorage` | Оставить опционально: секрет прокси живёт в Kotlin; `flutter_secure_storage` — если появится клиентский секрет |
| Push/Firebase/HMS/AppMetrica/MapKit | Удалить зависимости и инициализацию |
| API/Dio | Удалить backend-API; `dio` оставить только для GitHub Releases |

Зависимости: `drift`, `drift_flutter` (или `sqlite3_flutter_libs` + `path_provider`), `drift_dev`, `build_runner`, `package_info_plus`, `url_launcher`, `share_plus`, `file_picker`, `http`, локальный `tg_proxy_core` (path). `tg_proxy_core` зависит только от `pointycastle`, `crypto`, `async`, `collection`, `meta`; Flutter там нет. `hive_ce` и `hive_flutter` удаляются. `flutter_secure_storage` добавляется только при появлении клиентского секрета. `proxy_main.dart` импортирует `tg_proxy_core` и не импортирует UI-код.

### 7.2. Модуль `ProxyModule`

```
features/connection/
├── module/connection_routes.dart
├── pages/connection/{connection_page.dart,connection_wm.dart,connection_model.dart}
└── view/{status_card.dart,stats_grid.dart,link_card.dart,start_button.dart}

features/settings/
├── module/settings_routes.dart
├── pages/settings/{settings_page.dart,settings_wm.dart}
├── pages/dc/{dc_page.dart,dc_wm.dart}
├── pages/transport/{transport_page.dart,transport_wm.dart}
├── pages/advanced/{advanced_page.dart,advanced_wm.dart}
├── pages/botapi/{botapi_page.dart,botapi_wm.dart}
├── pages/appearance/{appearance_page.dart,appearance_wm.dart}
└── pages/data/{data_page.dart,data_wm.dart}

features/logs/
├── module/logs_routes.dart
└── pages/logs/{logs_page.dart,logs_wm.dart}

features/info/
├── module/info_routes.dart
└── pages/info/{info_page.dart,info_wm.dart}
```

`ProxyModule extends BaseAppModule`, регистрируется в `AppModel.modules`; провайдеры: `ProxyRepository`, `SettingsRepository`, `LogsRepository`, `UpdateRepository`.

### 7.3. Навигация

`StatefulShellRoute.indexedStack`, 4 ветки:

| Ветка | Маршрут | Экран |
|---|---|---|
| 1 | `/connection` | статус, старт/стоп, статистика, ссылка, QR, «Открыть в Telegram» |
| 2 | `/settings` | список разделов; вложенные `/settings/dc`, `/transport`, `/advanced`, `/botapi`, `/appearance`, `/data` |
| 3 | `/logs` | фильтры, поиск, автопрокрутка, экспорт |
| 4 | `/info` | версия, помощь, лицензии, обновления, отчёт |

Deep links: `tgwsproxy://connection`, `tgwsproxy://settings/...`, `tgwsproxy://logs`, `tgwsproxy://info`. Из tile preferences и уведомления открывается нужный маршрут через `Intent` + `AppLinkManager`.

Стартовый маршрут — `/connection`. Auth/PIN-редиректов нет.

### 7.4. Состояние и потоки

- `ProxyRepository` — singleton, держит `ValueNotifier<ProxyRuntimeState>` и `ValueNotifier<ProxyStats?>`.
- `bootstrap()` вызывает `getBootstrap`, подписывается на `proxy_events` и `logs`.
- `SettingsRepository` — кэш `ProxySettings` + методы `save/export/import`; после сохранения обновляет state.
- `AppDatabase` (Drift) — открывается в `runner.dart`, закрывается в `ApplicationWM.dispose`; таблица `prefs(key, value)` для `onboarding_seen`, `last_tab`, позиции скролла. Настройки прокси сюда не пишутся.
- `LogsRepository` — ring buffer на 2000 записей в Dart (для UI), источник — EventChannel.
- WM подписываются на репозитории, обновляют модель, вызывают методы канала.
- При `AppLifecycleState.resumed` — `refresh()` (state + settings), при `paused` — отписка от stats-потока (сервис продолжает работать).
- Ошибки канала → `ProxyException(code, message)` → снэкбар + лог.

### 7.5. Локализация и темы

- `intl_utils` + ARB: RU (основной), EN. Все строки UI — `S.current.*`.
- Native-строки уведомления/тайла — `res/values/strings.xml` + `values-ru`; язык уведомления берётся из сохранённой локали.
- `ThemeBuilder`: light/dark/system, seed color, палитры; `dynamic_color` для Android 12+; fallback — брендовый цвет.
- Edge-to-edge, portrait по умолчанию; крупные touch-target, content descriptions, поддержка масштаба шрифта.

### 7.6. Рефакторинг на базовый слой base-flutter (до Elementary)

**Референсный коммит:** `34e5ba68` («Удалил livekit», 2026-08-05) — последний коммит `base-flutter` **до** внедрения Elementary. Elementary пришёл в `2d84851d` («Внедрить Elementary в страницы базового», 2026-08-06). В `34e5ba68` уже есть базовые страницы, модели и mixin'ы; их и берём за образец.

Что переносим/адаптируем (без auth, backend, push, карт и Elementary):

| Компонент | Роль |
|---|---|
| `BasePage` / `BasePageState` | Scaffold/AppBar/drawer/SafeArea/loading/error/toast, `subscriptions`, `showLoadingIndicator`, `showMessage`, `showError` |
| `BasePageModelMixin` | `createModel()`, `ChangeNotifierProvider.value` + `Consumer`, привязка/отвязка listener, dispose модели |
| `BaseModel` / `SafeChangeNotifier` | `ChangeNotifier` с защитой от dispose, `IBaseModelListener`, `addError`, `addMessage`, `notifyModelListeners` |
| `BaseDataModel<T>` | `data`, `isLoading`, `loadData/reloadData`, реакции на resume/network |
| `ListModel<T>` | порционная загрузка, `isAllLoaded`, `offset`, `items`, фильтрация, add/remove/replace |
| `BaseInfinityScrollPageState` | infinity scroll, пустой список, ошибка, preload, `reloadData` |
| `BaseListViewPageState` | ListView + separators, header/footer, refresh indicator, `buildListItemImpl` |
| `BaseGridViewPageState` | GridView + `CalculateGridMixin` |
| `AppModelAccessMixin` / `ModuleFastAccessMixin` | доступ к `AppModel`/модулям; в нашем приложении — только `ProxyModule`, без `AuthModule`/`ShopModule` |

Целевой рефакторинг (после этапов 6A–6C, не сейчас):

1. Скопировать базовые файлы из `34e5ba68` в `lib/core/base/`, вычистить `AuthService`, `AppUser`, `AppApi`, `SideMenu`, `NavigationMode`, `flutter_auto_size_text`; `WTSLogger` заменить на текущий логгер.
2. `ConnectionPage` → `BasePage`; `ConnectionWM` → `ConnectionModel extends BaseModel` (или `BaseDataModel<ProxySnapshot>`), доступ к `ProxyRepository` через конструктор/провайдер, а не через `context.read` внутри view.
3. `SettingsPage` → `BasePage` + `SettingsModel`; вложенные `WorkersPage` → `BasePage` + `ListModel<WorkerDomain>`; `LogsPage`/`InfoPage` → `BasePage`.
4. Правило: страница не ходит в канал напрямую; всё через модель, модель — через репозиторий. `BasePageModelMixin` сам создаёт/диспозит модель и показывает `lastError`/message.
5. Тесты: widget-тесты на `BasePage` (loading/error/empty), unit-тесты `ListModel` (порции, конец списка, ошибка), рефакторинг экранов без изменения поведения.

Это **не** возврат Elementary: только `provider` + `StatefulWidget` + базовые классы из коммита `34e5ba68`.

---

## 8. Android / Kotlin слой

### 8.1. Классы и обязанности

> **Факт (v1.2).** Реализованы: `MainActivity`, `ProxyBridge`, `ProxyEngineHost`, `ProxyService`, `ProxyController`, `ProxyTileService`, `BootReceiver`, `SettingsStore`, `SecretStore`, `ProxyStateRepository`. Отдельного класса `EngineChannel` нет — канал живёт внутри `ProxyEngineHost`. Пока **не реализованы**: `ConnectionWatch`, `StallDetector`, TLS/plain-проба CF, auto-port, `LogRepository` с файлами, `TelegramLauncher` с chooser, `UpdateInstaller`, `UpdateCheckJob`. Таблица ниже — целевая декомпозиция.

| Класс | Обязанность |
|---|---|
| `MainActivity` | Flutter UI engine, регистрация `ProxyBridge`, deep links, `singleTask` |
| `ProxyBridge` | MethodChannel-методы, EventChannel-стримы state/stats/logs |
| `ProxyEngineHost` | headless `FlutterEngine` сервиса: `proxyMain`, канал, ready/start/stop, watchdog |
| `EngineChannel` | JSON-протокол Kotlin ↔ Dart-ядро, таймауты, буферизация логов |
| `ProxyConfig` | JSON-сериализация настроек, валидация, дефолты, схема v1 |
| `SettingsStore` | DataStore Preferences: все прокси-настройки, тема, язык, update |
| `SecretStore` | генерация 16 байт `SecureRandom`, AES-GCM через Android Keystore, хранение base64 |
| `ProxyController` | собрать `ProxyConfig`, проверить/подобрать порт, запустить/остановить сервис, рестарт |
| `ProxyService` | FGS, wakelock, engine start/stop, stats ticker, notification, START_REDELIVER_INTENT |
| `ConnectionWatch` | callback сети, StallDetector 60 с, TLS/plain проба CF, авто-`noSecure` |
| `ProxyNotification` | канал, ongoing-уведомление, действия Stop/Restart/Open, статистика |
| `ProxyStateRepository` | `StateFlow<ProxyRuntimeState>`, единый для сервиса, тайла и моста |
| `LogRepository` | bounded ring buffer, файловые логи с ротацией, редактирование секрета/домена |
| `ProxyTileService` | QS tile: toggle, состояние, открытие приложения |
| `BootReceiver` | автозапуск после загрузки, если включено |
| `TelegramLauncher` | `tg://proxy?...`, chooser по списку пакетов |
| `UpdateInstaller` | установка скачанного APK через FileProvider/PackageInstaller |
| `UpdateCheckJob` | ежедневная проверка GitHub Releases + уведомление |

### 8.2. Жизненный цикл сервиса

> **Факт (v1.2).** Старт/стоп/restart, boot, tile, FGS и headless engine работают на Android 16. `ProxyEngineHost` использует один `FlutterEngineGroup` на весь сервис и переиспользует `ProxyEngineHost` между стартами; entrypoint — `package:tgwsproxy/main.dart`, функция `proxyMain`, потому что Flutter не разрешил entrypoint из отдельной библиотеки. Ready-timeout — 30 с. Wakelock берётся на 1 час без продления. Auto-port, watchdog, `ConnectionWatch`/stall/TLS-проба и аккуратный restart без гонки UI ещё не реализованы — см. §21.

```
Пользователь нажал Start (UI)
  └─ MethodChannel.start
      └─ ProxyController: startForegroundService(ACTION_START)
          └─ ProxyService.onCreate: канал, wakelock
              ├─ startForeground(id, notification)  ← сразу, до engine
              ├─ ProxyEngineHost (один на сервис, FlutterEngineGroup)
              │    ├─ DartEntrypoint('package:tgwsproxy/main.dart', 'proxyMain')
              │    ├─ automaticallyRegisterPlugins = false
              │    └─ MethodChannel '.../engine'
              ├─ wait 'ready' ≤30 с, затем engine.start(configJson)
              │    ├─ Dart bind OK → 'started' → Running
              │    └─ 'error'      → Error(code, detail)
              ├─ stats ticker каждые 2 с → StateFlow + notification
              └─ START_STICKY: при рестарте процесса параметры из DataStore

Stop: ACTION_STOP → engine.stop() → 'stopped' → engine.destroy() → stopForeground → stopSelf
Restart: ACTION_RESTART → stop ≤5 с → start с текущим конфигом
Boot: BootReceiver → если autoStart → startForegroundService(ACTION_START)
Tile: TileService.onClick → Running ? STOP : START
```

Особенности:

- `startForeground` вызывается до создания engine, иначе Android 12+ бросит исключение.
- `stopWithTask=false`: свайп приложения не убивает прокси.
- Wakelock `PARTIAL_WAKE_LOCK` 1 час, release при остановке; продление пока не сделано.
- Порт пока фиксированный 1443; проверка занятости и auto-port — этап 6B.
- Headless engine не вызывает `runApp`, не регистрирует плагины и не зависит от Activity; UI engine живёт отдельно. Оба — в одном процессе, состояние только через Kotlin `StateFlow`.
- Watchdog: если 15 с нет `stats`/`ping`, engine перезапускается (не более 3 раз за 10 минут) — **цель**, не реализовано.
- `ConnectionWatch`: смена Wi-Fi ↔ mobile или возврат из авиарежима → рестарт ядра (15 с на стабилизацию, 3 с после потери); та же сеть — без рестарта. Нет трафика 60 с при ≥3 попытках → проба CF (TLS 443 vs plain 80), при TLS-блокировке авто-`noSecure` — **цель**, не реализовано.
- Сервис не работает в отдельном `:proxy` процессе: это усложнило бы каналы и состояние. При желании — будущий ADR с AIDL.

### 8.3. Манифест

Permissions:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
```

`REQUEST_INSTALL_PACKAGES` нужен только для встроенного обновления; если установка через браузер — убрать.

Компоненты:

```xml
<activity android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTask">
    <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
    </intent-filter>
    <intent-filter>
        <action android:name="android.intent.action.VIEW"/>
        <category android:name="android.intent.category.DEFAULT"/>
        <category android:name="android.intent.category.BROWSABLE"/>
        <data android:scheme="tgwsproxy"/>
    </intent-filter>
</activity>

<service android:name=".service.ProxyService"
    android:exported="false"
    android:foregroundServiceType="specialUse"
    android:stopWithTask="false">
    <property
        android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
        android:value="Local MTProto proxy server"/>
</service>

<service android:name=".service.ProxyTileService"
    android:exported="true"
    android:icon="@drawable/ic_tile"
    android:label="@string/tile_label"
    android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
    <intent-filter>
        <action android:name="android.service.quicksettings.action.QS_TILE"/>
    </intent-filter>
    <meta-data android:name="android.service.quicksettings.ACTIVE_TILE" android:value="true"/>
</service>

<receiver android:name=".service.BootReceiver"
    android:exported="true"
    android:enabled="true">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
        <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
        <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
</receiver>
```

`<queries>` — список Telegram-пакетов из Android-репозитория (Telegram, Telegram X, Plus, NekoGram, AyuGram, exteraGram и др.). Нужен для `resolveActivity` и chooser без `QUERY_ALL_PACKAGES`.

`android:allowBackup="false"`, `android:fullBackupContent="false"`, `android:dataExtractionRules="@xml/data_extraction_rules"` (исключить DataStore/secret). `android:networkSecurityConfig` не требуется: наружу только TLS, локально — raw TCP.

R8: специальных keep-правил для ядра нет — нативных символов и JNI нет. `MainActivity`, `ProxyService`, `ProxyEngineHost` и `EngineChannel` помечаются `@Keep`, если R8 начнёт вырезать точки входа; Flutter-классы сохраняются стандартными правилами Flutter Gradle Plugin.

### 8.4. Foreground service и уведомление

- Канал `proxy_service`, `IMPORTANCE_LOW`, без звука.
- Заголовок: «Прокси работает» / «Остановлен».
- Текст: `↑ 1.2 MB · ↓ 8.4 MB · 3 соединения` (обновление 2 с; при старте — 500 мс).
- Действия: `Open Telegram`, `Stop`; tap → `/connection`. `Restart` доступен из UI и тайла.
- На Android 13+ разрешение `POST_NOTIFICATIONS` запрашивается на первом старте; если отказано — сервис работает, в UI баннер «Уведомление скрыто».
- На Android 14+ `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`; subtype property обязателен.
- На Android 15+ не полагаться на автозапуск FGS с boot на всех OEM: тестировать; при запрете — лог и уведомление «Автозапуск заблокирован системой».

### 8.5. QS Tile

- `TileService` с `ACTIVE_TILE`; состояние `ACTIVE/INACTIVE`, subtitle `Running/Stopped`.
- Click: если `Running` → `ACTION_STOP`, иначе `ACTION_START`.
- После смены состояния сервис вызывает `TileService.requestListeningState(context, ComponentName(...))`.
- Long-press (Android 13+) → `startActivityAndCollapse` на `/settings`; на старых — `ProxyTilePreferencesActivity` можно не делать, сразу открывать приложение.

### 8.6. BootReceiver

- Читает `autoStartOnBoot` из DataStore.
- Запускает `startForegroundService(ACTION_START)`.
- Данные приложения лежат в credential-encrypted storage: до первого разблокирования `BOOT_COMPLETED` не приходит, поэтому `LOCKED_BOOT_COMPLETED` не используем.
- Ошибки (Keystore недоступен, порт занят) — в лог; не крашим ресивер.

### 8.7. Хранилище

**DataStore Preferences** (канон):

```
schema_version, port, bind_ip, secret_enc, dc_auto, dc1..dc5, dc203,
dc1_media..dc5_media, dc203_media, pool_size, cf_enabled, cf_priority,
cf_user_enabled, cf_user_domains, cf_worker_enabled, cf_worker_domains,
h2_enabled, fake_tls_domain, force_test_dc, no_secure, proxy_protocol,
buf_kb, ws_keepalive_sec, botapi_enabled, botapi_port,
verbose, log_to_file, log_max_mb, log_levels, auto_start_on_boot,
theme_mode, dynamic_color, palette, locale, update_enabled,
update_interval_hours, last_update_check, postponed_version,
auto_port_picked, no_secure_auto
```

`secret_enc` — base64(AES-GCM(secret)) с ключом в Android Keystore (alias `tgwsproxy_secret`). Секрет генерируется при первом запуске: 16 байт `SecureRandom` → 32 hex. При смене FakeTLS-домена ссылка меняется (`ee` + secret + hex(domain)); сам секрет не меняется. `buf_kb` читается для импорта, но в UI скрыт и в движок не передаётся (ADR-13). `no_secure_auto` показывает, что `no_secure` включён автоматически после TLS-пробы, чтобы UI мог предложить вернуть TLS.

**Drift (Flutter)** — локальная SQLite-БД `app.db`, только UI-состояние: таблица `prefs(key TEXT PRIMARY KEY, value TEXT)` для `onboarding_seen`, `last_tab`, позиции скролла. Схема версионируется миграциями Drift; настройки прокси сюда не дублируются, логи остаются в Kotlin/памяти и в файле. `flutter_secure_storage` — только если появится клиентский секрет (например, токен приватного репозитория обновлений); секрет прокси хранится в Android Keystore.

---

## 9. Dart-ядро

### 9.1. Источник и стратегия порта

Ядро — отдельный пакет `packages/tg_proxy_core`, чистый Dart без Flutter. Источник — Python-ядро Flowseal из `AndMTProto` (MIT, 4644 LOC), которое сейчас работает на Android через Chaquopy. Python в APK не остаётся; порт сохраняет структуру, константы и тестовые векторы.

| Python (`proxy/`) | Dart (`lib/src/`) |
|---|---|
| `config.py` | `config/config.dart` |
| `utils.py` | `config/constants.dart` |
| `_aes.py` | `crypto/aes_ctr.dart` |
| `tg_ws_proxy.py` | `proxy/server.dart`, `proxy/client_handler.dart`, `mtproto/handshake.dart` |
| `bridge.py` | `proxy/bridge.dart`, `mtproto/splitter.dart` |
| `pool.py` | `transport/ws_pool.dart`, `transport/cf_worker.dart` |
| `raw_websocket.py` | `transport/raw_websocket.dart`, `transport/tls.dart` |
| `fake_tls.py` | `faketls/server.dart`, `faketls/records.dart` |
| `cf_h2.py`, `h2_transport.py` | `h2/pool.dart`, `h2/transport.dart` — **этап 2** |
| `balancer.py` | `cfproxy/balancer.dart` |
| `event_loop.py` | `proxy/server.dart` (asyncio → Dart async) |
| `network_debug.py` | `network_debug.dart` |
| `stats.py` | `stats.dart` |
| — | `botapi/proxy.dart` (новое, см. §11) |

### 9.2. Алгоритмы, которые обязаны совпасть

- **Handshake:** 64 байта; ключ `SHA256(prekey[8..40] + secret)`, IV `handshake[40..56]`; проверка proto-тега на 56 (`EF/EE/DD`); DC — signed int16 LE на 60, отрицательный = media. Тестовый DC: `dc >= 10000` или `forceTestDc`, затем `dc -= 10000`.
- **Relay init:** 64 случайных байта, первый байт не `0xEF`, первые 4 не входят в reserved-starts (`HEAD/POST/GET/EE/DD/TLS/OPTI`), байты 4..8 не все нули; хвост — proto + DC + 2 случайных; целиком шифруется relay-ключом.
- **AES-CTR:** ключи `clt_dec = SHA256(prekey + secret)`, `clt_enc = SHA256(reverse(prekey + iv)[:32] + secret)`, relay enc/dec из relay init; пропуск первых 64 байт keystream; **шифруется весь поток в обе стороны**, не только заголовок.
- **MsgSplitter:** abridged (`0x7F/0xFF`, 3-байтная длина ×4) и intermediate (4-байтная LE `& 0x7FFFFFFF`), padded intermediate; при ошибке splitter отключается, поток идёт как есть.
- **FakeTLS:** ClientHello/HMAC-SHA256, replay cache, ServerHello, CCS, appdata, профиль длины appdata, 301 на masking-домен для не-TLS; таймауты 10 с.
- **WS:** собственный HTTP Upgrade поверх `SecureSocket`/`Socket`, `Sec-WebSocket-Protocol: binary`, маскирование клиентских кадров, ping/pong, фрагментация, лимит 16 МБ, keepalive 30 с, read timeout 120 с. `dart:io WebSocket` не используем (нет контроля SNI/буферов/backpressure).
- **Пулы:** WS на DC (reuse 120 с, прогрев, refill), CF worker pool (100 с), CF-домены: `kws{dc}.{domain}` и `kws{dc}-1.web.telegram.org`, `/apiws`; worker — `/apiws?dst=<ip>&dc=<dc>`; `secure = !no_secure`.
- **Fallback:** worker → CF proxy/H2 → прямой TCP 443 с экспоненциальным backoff 30..3600 с; 429 cooldown 45..300 с.
- **H2-медиа:** `cf_h2`/`h2_transport` — HTTP/2 POST-стриминг через CF, replay/backpressure/каналы. Первый релиз — без H2; флаг `h2_enabled` выключен, медиа идёт через WS/CF. Порт — отдельный этап с отдельными тестами.
- **Статистика:** active, total, lastHour, badRecent, ws, cf, h2, tcpFb, routed, bytesUp/Down, pool/cfPool hits/misses, errors.

### 9.3. Runtime и конфиг

- `proxyMain` создаёт `ProxyServer`, ждёт `start(configJson, pathsJson)`, биндит `127.0.0.1:port` и `127.0.0.1:botapiPort`, отдаёт `started`/`stopped`/`stats`/`log`/`error`.
- `EngineConfig` — тот же JSON, что в §10.5; пути `{cacheDir, logDir, filesDir}` передаются отдельно. DataStore — канон, Dart валидирует повторно.
- Один event loop на engine; клиентские задачи учитываются в `Set<Future>` и отменяются при stop; listener watchdog 5 с.
- Логи: буфер + файл `proxy.log` с ротацией `log_max_mb`, redaction секрета и CF-домена; `verbose` — debug.
- Ошибки: `bad_secret`, `bad_port`, `bad_dc_ip`, `bad_fake_tls`, `port_in_use` (+`suggestedPort`), `permission`, `address`, `unknown`; на старте — событие `error` с кодом и текстом.

### 9.4. Производительность и ограничения

- **AES-CTR:** PointyCastle, обработка чанками 64 КБ, минимум аллокаций; обязательный бенчмарк на ARM (цель ≥10–20 МБ/с, типичный Telegram mobile — <5 МБ/с). Если ниже — узкий `dart:ffi`-примитив AES-CTR (BoringSSL/AES-NI), логика остаётся в Dart; это отдельный ADR.
- **TLS-кривые:** Python ставит X25519, чтобы DPI не тормозил большой post-quantum ClientHello. `dart:io SecureSocket` не даёт выбрать группы; риск — измерить на проблемных сетях, при необходимости `no_secure` (порт 80) или FFI-BoringSSL. Это главный технический риск порта.
- **Буферы:** `bufferSizeKb` не применяется (ADR-13); TCP_NODELAY ставится, размеры буферов — дефолт ОС.
- **Память:** два FlutterEngine; цель — <150 МБ PSS в простое, замер на 2 ГБ устройствах. `FlutterEngineGroup` используют оба engine, иначе shared resources не работают: UI-движок создаётся кастомным `FlutterActivity`, сервисный — той же группой.
- **Backpressure:** ограниченные очереди WS, `flush` при превышении порога, pause чтения клиента.

### 9.5. Зависимости и проверка

`packages/tg_proxy_core/pubspec.yaml`: `pointycastle`, `crypto`, `async`, `collection`, `meta`; для H2-этапа — `http2` (или собственный HTTP/2-клиент). Тесты: `dart test`, бенчмарк `dart run benchmark/aes_ctr_benchmark.dart`. Векторы берём из Python-тестов и снятых pcap/handshake-примеров; сравнение с эталонным Python-ядром на одном наборе входов. Сборка APK — только `flutter build apk`, без cargo/NDK/Chaquopy.

---

## 10. Контракты

### 10.1. MethodChannel `com.example.tgwsproxy/proxy`

Все аргументы/результаты — JSON-строки или примитивы.

| Метод | Аргумент | Результат |
|---|---|---|
| `getBootstrap` | — | `{settings, state, secretMasked, secretWithPrefix, version, engineVersion, abi, device, capabilities}` |
| `start` | — | `{state}` |
| `stop` | — | `{state}` |
| `restart` | — | `{state}` |
| `getState` | — | `{state}` |
| `getStats` | — | `{stats}` |
| `probeCf` | — | `{tls: Bool, plain: Bool, latencyMs}` — диагностика блокировки CF |
| `updateSettings` | `{settingsJson}` | `{settings, restartRequired}` |
| `getSecret` | — | `{secret, secretWithPrefix}` — только по явному действию «Показать» |
| `regenerateSecret` | — | `{secretMasked, restartRequired}` |
| `getProxyLink` | — | `{link}` |
| `openInTelegram` | — | `{opened: Bool}` |
| `getLogs` | `{limit, levels}` | `{entries}` |
| `clearLogs` | — | `{ok}` |
| `exportLogs` | — | `{path}` |
| `exportSettings` | `{includeSecret: Bool}` | `{json}` |
| `importSettings` | `{json}` | `{settings, restartRequired}` |
| `getDiagnostics` | — | `{text}` |
| `openBatterySettings` | — | `{ok}` |
| `installUpdate` | `{path}` | `{started}` |
| `log` | `{level, tag, message}` | `{ok}` |

### 10.2. EventChannel `.../proxy_events`

События:

```json
{"type":"state","state":{"status":"running","since":1730000000,"errorCode":null,"errorMessage":null,"restartRequired":false,"port":1443}}
{"type":"stats","stats":{"total":10,"active":2,"lastHour":4,"badRecent":0,"ws":8,"cf":7,"h2":0,"tcpFallback":1,"routed":9,"errors":0,"poolHits":5,"poolTotal":6,"cfPoolHits":3,"cfPoolTotal":4,"bytesUp":123456,"bytesDown":987654,"uptimeSec":60}}
```

Период: 2 с, только пока есть подписчик. При `paused` Flutter отписывается; сервис продолжает обновлять уведомление. `routed` — соединения, ушедшие через WS/CF/H2 (не TCP fallback).

### 10.3. EventChannel `.../logs`

```json
{"ts":1730000000123,"level":"info","tag":"ProxyService","message":"started on 127.0.0.1:1443"}
```

Ring buffer 2000; при переполнении старые вытесняются. Файл — опционально.

### 10.4. MethodChannel `com.example.tgwsproxy/engine` (сервис ↔ Dart)

Канал живёт внутри headless engine. Аргументы — JSON-строки.

Kotlin → Dart:

| Метод | Аргумент | Ответ |
|---|---|---|
| `start` | `{config, paths:{cacheDir,logDir,filesDir}}` | `{ok, port}` / `{error:{code,message,suggestedPort}}` |
| `stop` | — | `{ok}` |
| `restart` | `{config, paths}` | `{ok, port}` |
| `updateConfig` | `{config}` | `{ok, restartRequired}` |
| `getStats` | — | `{stats}` |
| `ping` | — | `{pong: true}` |

Dart → Kotlin (через `invokeMethod` на том же канале или отдельный callback-канал):

```json
{"type":"ready","version":"1.0.0"}
{"type":"started","port":1443,"botApiPort":8081}
{"type":"stopped","reason":"user"}
{"type":"stats","stats":{...}}
{"type":"log","entries":[{"ts":1730000000123,"level":"info","tag":"proxy","message":"..."}]}
{"type":"error","error":{"code":"PORT_IN_USE","message":"...","suggestedPort":1444}}
```

Правила:

- Сервис создаёт engine, ждёт `ready` не более 10 с; только потом `start`. Если `ready` нет — `ENGINE_TIMEOUT`.
- `stats`/`ping` — heartbeat; 15 с тишины → рестарт engine (максимум 3 за 10 минут).
- `stop` идемпотентен; сервис ждёт `stopped` до 5 с, затем уничтожает engine.
- Логи батчатся (100 мс / 50 записей), чтобы не забивать канал.
- Секрет в логах маскируется на стороне Dart до отправки.

### 10.5. JSON настроек (схема v1)

```json
{
  "schemaVersion": 1,
  "port": 1443,
  "bindIp": "127.0.0.1",
  "secret": "0123456789abcdef0123456789abcdef",
  "dcAuto": true,
  "dcIps": ["2:149.154.167.220", "4:149.154.167.220"],
  "experimental": false,
  "poolSize": 4,
  "cfproxyEnabled": true,
  "cfproxyUserEnabled": false,
  "cfproxyUserDomains": [],
  "cfproxyWorkerEnabled": false,
  "cfproxyWorkerDomains": [],
  "h2Enabled": false,
  "fakeTlsDomain": "",
  "forceTestDc": false,
  "noSecure": false,
  "proxyProtocol": false,
  "bufferSizeKb": 256,
  "wsKeepaliveSec": 30,
  "botApi": {"enabled": false, "host": "127.0.0.1", "port": 8081},
  "verbose": false,
  "logToFile": false,
  "logMaxMb": 5,
  "locale": "system",
  "autoStartOnBoot": false,
  "autoPort": true
}
```

`dcIps`: `<dc>:<ip>`; отрицательный `dc` — media-вариант (`-2:...`). При `dcAuto=true` список собирается из дефолтов/полей DC; при `experimental=true` добавляются 5, 203 и media.

Валидация:

| Поле | Правило |
|---|---|
| `port` | 1024–65535; 443 запрещён (root) |
| `bindIp` | IPv4 loopback по умолчанию; смена на `0.0.0.0` — предупреждение |
| `secret` | 32 hex; генерируется, если пусто/невалиден |
| `poolSize` | 1–16 |
| `bufferSizeKb` | 32–1024; принимается для импорта, но **не применяется** (ADR-13) |
| `wsKeepaliveSec` | 10–300 |
| `botApi.port` | 1024–65535, не равен `port` |
| `dcIps` | каждый элемент `^-?\d{1,3}:\d{1,3}(\.\d{1,3}){3}$` |
| `fakeTlsDomain` | пусто или валидный hostname |
| `cfproxyUserDomains` | 0–20 hostname |
| `cfproxyWorkerDomains` | 0–20 hostname |
| `h2Enabled` | принимается, но в v1 не активен (ADR-15); UI показывает «этап 2» |
| `noSecure` | bool; UI предупреждает, что TLS отключён |

Импорт: проверить `schemaVersion`, мигрировать, не запускать прокси автоматически. Экспорт «для шаринга» без секрета; «полный бэкап» — с секретом и предупреждением.

### 10.6. Коды ошибок

| Код | Значение | UI |
|---|---|---|
| `ENGINE_START_FAILED` | Dart-ядро не стартовало | «Ядро не запустилось», отчёт |
| `ENGINE_TIMEOUT` | нет `ready`/`started` за 10 с | лог, предложить рестарт |
| `ENGINE_CRASHED` | engine умер / watchdog | авто-рестарт, затем Error |
| `INVALID_CONFIG` | валидация (`bad_secret`, `bad_port`, `bad_dc_ip`, `bad_fake_tls`) | подсветить поле |
| `PORT_IN_USE` | порт занят | «Порт 1443 занят», `suggestedPort` |
| `PERMISSION_DENIED` | нет прав на bind | инструкция |
| `ALREADY_RUNNING` | повторный старт | просто показать Running |
| `NOT_RUNNING` | stop при остановленном | игнор |
| `START_TIMEOUT` | ядро не ответило | лог, предложить рестарт |
| `STOP_TIMEOUT` | `stopped` не пришёл | лог, state Error |
| `BOTAPI_BIND_FAILED` | 8081 занят | предупреждение, основной прокси работает |

---

## 11. Bot API на Android

### 11.1. Почему не hosts

Десктопный Bot API правит hosts и слушает `127.0.0.2:443`, чтобы `api.telegram.org` прозрачно шёл через прокси. На Android это требует root и ломает проверку SSL у клиентов. Поэтому адаптация:

**Локальный HTTP CONNECT-прокси** на `127.0.0.1:8081` (порт настраивается). Клиент бота (библиотека, скрипт, приложение) явно указывает HTTP-прокси. Трафик до `api.telegram.org:443` идёт через тот же CF Worker, TLS остаётся end-to-end между клиентом и Telegram.

```
Bot client ──CONNECT api.telegram.org:443──► 127.0.0.1:8081 (Dart botapi)
   ◄──200 Connection Established────────────┘
   ──TLS(api.telegram.org)──────────────────► CF Worker /apiws?dst=api.telegram.org
                                              └──TCP──► api.telegram.org:443
```

### 11.2. Реализация

`packages/tg_proxy_core/lib/src/botapi/proxy.dart`:

- `HttpServer.bind(InternetAddress.loopbackIPv4, botApiPort)`; только loopback.
- Парсинг `CONNECT host:port HTTP/1.1`; allowlist только `api.telegram.org:443` (защита от open proxy).
- Установка WS к CF Worker: путь `/apiws?dst=api.telegram.org`, тот же пул/балансер и проверка TLS, что у основного прокси.
- Только после успешного WS — ответ `HTTP/1.1 200 Connection Established`; иначе `502`.
- Двунаправленный relay TCP↔WS (переиспользовать `bridge`), без AES: байты TLS клиента идут как есть.
- Таймауты: handshake 15 с, idle 120 с; лог без токенов.
- При остановке движка listener закрывается; ошибка bind не валит основной прокси.

Ограничения:

- Работает только с клиентами, которые умеют HTTP-прокси (`HTTPS_PROXY`, настройки библиотеки).
- Не перехватывает приложения, игнорирующие системный прокси.
- Публичные CF Worker должны поддерживать `dst` (десктопный worker поддерживает). Свой worker — предпочтительно.

### 11.3. UI

Экран `/settings/botapi`:

- тумблер «Bot API через локальный прокси»;
- порт (по умолчанию 8081), кнопка «Копировать адрес»;
- инструкция: `HTTPS_PROXY=http://127.0.0.1:8081`, пример `curl -x http://127.0.0.1:8081 https://api.telegram.org/bot<TOKEN>/getMe`;
- предупреждение: токен не логируется, но клиент должен доверять устройству;
- кнопка «Проверить» (опционально, post-MVP): открыть WS и вернуть latency.

---

## 12. Функциональный паритет

> Это **целевая** матрица. Фактическое состояние Android MVP и незакрытые пункты — в §21; не все ✅ здесь уже реализованы.

### 12.1. Матрица

| Функция | Десктоп | AndMTProto сейчас | Новое приложение |
|---|---|---|---|
| Движок | Python | Python/Chaquopy | Чистый Dart |
| Локальный MTProto-прокси | ✅ | ✅ | ✅ |
| WSS через CF + TCP fallback | ✅ | ✅ | ✅ |
| Пул WS/CF, балансер, 429 cooldown | ✅ | ✅ | ✅ |
| FakeTLS (`ee`) | ✅ | ✅ | ✅ UI + replay-защита |
| CF user domain | ✅ | ✅ | ✅ |
| CF worker domains | ✅ | ✅ | ✅ UI |
| Proxy protocol | ✅ | ⚙️ ядро умеет, UI нет | ✅ advanced |
| Force test DC | ✅ | ✅ | ✅ advanced |
| Buffer size | ✅ | ⚙️ поле есть, эффекта нет | ❌ не поддерживается (ADR-13) |
| WS keepalive | ✅ | ❌ фикс 30 с | ✅ Dart-таймер |
| Pool size | ✅ | ✅ | ✅ |
| DC auto/manual | ✅ | ✅ | ✅ |
| DC 5/203/media (experimental) | ✅ | ✅ | ✅ |
| Secret + regenerate | ✅ | ✅ | ✅ |
| Host/port | ✅ | ✅ | ✅ |
| Auto-port при занятом 1443 | — | ✅ | ✅ |
| Verbose | ✅ | ✅ | ✅ (лог-уровень) |
| Файловые логи + ротация | ✅ | ✅ | ✅ |
| JSON config import/export | ✅ | ❌ | ✅ |
| Полный экран статистики | ✅ (summary) | ⚙️ частично | ✅ |
| Bot API | ✅ (hosts/root) | ❌ | ✅ локальный HTTP CONNECT |
| H2-медиа через CF | ✅ | ✅ | ⏳ этап 2 (ADR-15) |
| `no_secure` (CF по порту 80) | ✅ | ✅ | ✅ |
| TLS-проба CF и авто-`no_secure` | — | ✅ | ✅ |
| Рестарт при смене сети | — | ✅ | ✅ |
| Stall detector 60 с | — | ✅ | ✅ |
| Автозапуск | ✅ (Win) | ✅ boot | ✅ |
| Проверка обновлений | ✅ | ✅ | ✅ |
| Язык RU/EN | ✅ | ✅ | ✅ |
| Темы/палитры/dynamic color | ✅ | ✅ | ✅ |
| Tray | ✅ | — | — (заменён notification/tile) |
| Portable mode | ✅ | — | — |
| CLI-флаги | ✅ | — | — (deep links вместо) |
| QS tile | — | ✅ | ✅ |
| Foreground service | — | ✅ | ✅ |
| Notification actions | — | ✅ | ✅ |
| Apply in Telegram + chooser | — | ✅ | ✅ |
| Отчёт диагностики | — | ✅ | ✅ |
| Лог-вьюер с фильтрами | — | ✅ | ✅ |
| Wakelock | — | ⚙️ неявно | ✅ явный |
| Без аналитики | ✅ | ✅ | ✅ |

### 12.2. Что именно добавляем из десктопа

1. UI для FakeTLS, CF worker domains, proxy protocol, force test DC; buffer size — только как поле импорта, без эффекта.
2. `ws_keepalive_interval` — Dart-таймер вместо фиксированных 30 с.
3. Файловые логи с ротацией (5 МБ × 3 по умолчанию) и redaction.
4. Импорт/экспорт JSON, полный бэкап с секретом.
5. Экран статистики: pool hits, CF pool, H2, errors, bytes, uptime.
6. Bot API через локальный HTTP CONNECT-прокси.
7. Явный verbose-режим и уровень логов.
8. Проверка обновлений с интервалом и отложенным напоминанием (уже есть, доводим UI).
9. `no_secure`, TLS-проба, stall detector, network restart, auto-port — переносим из AndMTProto.
10. H2-медиа — после MVP, отдельным этапом с флагом.

---

## 13. Основные сценарии

### 13.1. Первый запуск

1. Splash; `getBootstrap`.
2. Если секрета нет — Kotlin генерирует и сохраняет.
3. Показывается Connection: статус Stopped, ссылка `tg://proxy?server=127.0.0.1&port=1443&secret=dd...`.
4. Запрос `POST_NOTIFICATIONS` (Android 13+) при первом старте, не на старте приложения.
5. Подсказка «Открыть в Telegram» и выбор клиента.

### 13.2. Старт и применение в Telegram

1. Start → сервис → headless engine → Dart-ядро.
2. Running → ссылка активна, статистика пошла.
3. «Открыть в Telegram» → `Intent.ACTION_VIEW` с `tg://proxy...`; chooser по установленным пакетам.
4. Пользователь подтверждает прокси в клиенте.
5. В приложении — статус, трафик, активные соединения.

### 13.3. Смена настроек

1. Пользователь меняет поле → валидация на месте.
2. Save → `updateSettings` → DataStore.
3. Если прокси запущен: диалог «Нужен перезапуск» → `restart` или «Позже» (баннер `restartRequired`).
4. Исключения без перезапуска: тема, язык, фильтры логов, autostart, интервал обновлений.
5. Смена секрета/FakeTLS/порта/DC/транспорта — всегда перезапуск.

### 13.4. Boot / tile / свайп

- Boot: `BootReceiver` → проверка настройки → FGS. Если система запретила — лог, приложение при открытии покажет «Автозапуск не сработал».
- Tile: toggle без открытия UI; состояние берётся из `StateFlow`.
- Свайп: `stopWithTask=false`, сервис остаётся; уведомление продолжает жить.

### 13.5. Обновление

1. Info → «Проверить обновления» (или автоматически раз в N часов).
2. GitHub Releases API; semver-сравнение; канал `stable` (единственный).
3. Скачивание APK в `cacheDir/updates`, проверка SHA-256 из release-ассетов (если есть).
4. `UpdateInstaller` → FileProvider → `ACTION_VIEW`/PackageInstaller; пользователь подтверждает.
5. Если `REQUEST_INSTALL_PACKAGES` нет — открыть страницу релиза в браузере.

### 13.6. Смена сети, застой и блокировка CF

1. `ConnectivityManager` сообщает о смене сети; `ConnectionWatch` ждёт 15 с (3 с после потери) и перезапускает engine, если сеть действительно другая.
2. `StallDetector` следит за `routed`/`bytesDown`: 60 с без изменений при ≥3 попытках → `probeCf` (TLS 443 и plain 80).
3. Если TLS недоступен, а plain работает — включается `noSecure` с пометкой `noSecureAuto`, engine перезапускается; UI показывает карточку «CF блокируется по TLS, включён порт 80».
4. Если трафика нет и после этого — ещё один рестарт, затем карточка с диагностикой и ссылкой на лог; watchdog не даёт сервису умереть.

---

## 14. Безопасность и приватность

- **MTProto E2E**: содержимое сообщений шифруется между клиентом и Telegram; прокси видит только транспортные метаданные.
- **TLS проверяется**: Android — `SecureSocket` (корневые сертификаты, hostname); iOS Rust — `webpki-roots` в `TLS_CONFIG`. `NoVerify` остался только для явного SNI-fronting (`TLS_CONFIG_FRONTING`), где hostname не может совпасть по определению. MTProto остаётся E2E-шифрованным. `no_secure` выключен по умолчанию и открывает plain ws (порт 80) только по явному выбору. Остаточный риск — DPI по TLS-кривым: Dart не даёт зафиксировать X25519; при блокировке помогает `no_secure`/смена CF-домена, в перспективе — FFI-BoringSSL.
- **Секрет** — 16 случайных байт, хранится зашифрованным ключом Android Keystore; не пишется в логи; при показе — по явному действию; буфер обмена с ссылкой содержит секрет (предупреждение).
- **Локальные порты** по умолчанию только `127.0.0.1`. Смена bind IP на `0.0.0.0` — предупреждение «прокси доступен в локальной сети».
- **Bot API** слушает только loopback и разрешает только `api.telegram.org:443`; open proxy невозможен.
- **Логи**: маскировать 32-hex секреты, `bot<digits>:<token>`, `Authorization`; файлы — во внутреннем каталоге приложения, не в общем хранилище.
- **Backup** отключён: секрет и настройки не уходят в облако.
- **Разрешения** минимальны: нет камеры, геолокации, контактов, хранилища (file_picker использует SAF).
- **Сеть**: только CF/Telegram и GitHub API для обновлений; никакой телеметрии.
- **MIT**: исходники открыты; ссылка в Info; в релиз кладётся source archive (не обязано лицензией, но полезно).

---

## 15. Лицензирование

- Приложение и Dart-ядро: **MIT**. `LICENSE` + copyright Flowseal в производных файлах.
- `NOTICE`:
  - Flowseal/tg-ws-proxy — MIT, copyright Flowseal (Python-ядро);
  - oruviyex18/AndMTProto — MIT, Android-адаптер и UX;
  - amurcanov/tg-ws-proxy-android — GPLv3, не используется; только историческая ссылка.
- MIT не требует раскрывать исходники, но проект открыт: публичный репозиторий + source archive в релизах.
- Нельзя удалять copyright-уведомления Flowseal из портированных файлов.
- `base-flutter` — отдельный вопрос прав; до релиза подтвердить, что шаблон можно распространять под MIT.

---

## 16. Тестирование

### 16.1. Уровни

| Уровень | Что проверяем |
|---|---|
| Dart core unit | AES-CTR/KDF на тест-векторах, obfuscation-handshake, relay init, `MsgSplitter`, FakeTLS ClientHello/HMAC, WS-кадры и маскирование, CF-балансер, CONNECT-парсер, JSON-конфиг, stats |
| Dart core integration | поднятие движка на localhost с фейковым WS/DC, полный handshake, порядок fallback worker→CF→TCP, повторный старт, закрытие listener'а |
| Dart benchmark | PointyCastle AES-CTR на целевом ARM: 64 КБ чанки, gate ≥10 МБ/с, профиль памяти |
| Kotlin unit | `ProxyConfig` JSON, link builder, state machine, маскирование логов, auto-port/noSecure-флаги |
| Kotlin instrumented | `ProxyService` + headless engine start/stop, watchdog, BootReceiver, TileService, DataStore, уничтожение UI-процесса |
| Flutter unit/widget | модели/JSON, WM с фейковым репозиторием, форматирование статистики, Drift in-memory, экраны и ошибки канала |
| Integration | `integration_test`: старт → порт 1443 слушается → стоп → порт закрыт; смена настроек → рестарт; Bot API CONNECT |
| Manual | устройства/клиенты/сети, reboot, tile, Doze, airplane mode, блокировка CF по TLS |

### 16.2. Ручная матрица

- Android 10, 12, 13, 14, 15, 16; Pixel + Samsung + Xiaomi.
- Telegram, Telegram X, Plus, NekoGram, AyuGram, exteraGram.
- Wi-Fi, LTE, переключение сетей, airplane mode 1 мин, возврат в ту же сеть.
- Перезагрузка с autostart on/off; свайп из recents; убийство UI через настройки; Doze 1 ч.
- Занятый порт 1443 (auto-port и ошибка); неверный CF-домен; FakeTLS on/off; `no_secure` on/off.
- Блокировка CF по TLS: включить `no_secure`, проверить карточку и авто-переключение.
- Bot API: `curl -x http://127.0.0.1:8081 https://api.telegram.org/bot<TOKEN>/getMe`.
- Импорт/экспорт конфига, сброс настроек, регенерация секрета.
- 16 KB page: `adb shell getconf PAGE_SIZE` на 16 KB-устройстве/эмуляторе.
- Soak 8 ч: память (PSS двух engine), батарея, рост логов, стабильность WS и TCP-fallback.

### 16.3. Критерии приёмки MVP

1. Start/stop из UI, tile и после reboot; статус консистентен.
2. Telegram подключается через прокси на Wi-Fi и LTE; статистика растёт.
3. Настройки переживают убийство процесса и перезагрузку.
4. Ошибки порта/ядра показываются понятным текстом, не крашат приложение.
5. Логи открываются, фильтруются, экспортируются; секрет не утекает.
6. APK собирается для arm64/armv7/x86_64; 16 KB alignment подтверждён.
7. Bot API работает с `curl` через локальный прокси.
8. Импорт/экспорт конфига валидирует данные.
9. Headless engine переживает убийство UI и свайп; при смене сети перезапускается; stall-детектор включает `noSecure` при TLS-блокировке.
10. В APK нет Python/Chaquopy/JNI-библиотек; `packages/tg_proxy_core` проходит тесты отдельно от Flutter.

---

## 17. Сборка, CI/CD, релизы

### 17.1. Локально

```bash
make gen        # build_runner (Drift, routes, freezed)
make run        # flutter run
make apk        # flutter build apk --release --split-per-abi
make check      # analyze + flutter test + dart test packages/tg_proxy_core + 16kb
make core-test  # только Dart-ядро
make core-bench # AES-CTR на текущем устройстве/хосте
```

`Makefile` — тонкая обёртка; никакой логики в нём.

### 17.2. Gradle

- `compileSdk` из base-flutter (37), `targetSdk 36`, `minSdk 29`.
- `ndkVersion` не нужен: своего native-кода нет; Flutter Gradle сам собирает engine.
- `abiFilters`/`splits.abi`: `armeabi-v7a`, `arm64-v8a`, `x86_64`, `isUniversalApk = true`.
- `packaging.jniLibs.useLegacyPackaging = false` — 16 KB для библиотек Flutter.
- Signing: `android/key.properties` + keystore; в CI — secrets.
- R8: no native/JNI keep rules; при необходимости `@Keep` для entrypoint-классов.

### 17.3. CI (GitHub Actions)

`ci.yml`:

1. `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test`.
2. `dart test packages/tg_proxy_core`.
3. `make core-bench` (не блокирует, публикует числа; gate — отдельная nightly-джоба).
4. `flutter build apk --debug --split-per-abi`.
5. Kotlin unit tests.
6. `check_16kb.sh` по `libflutter.so` и итоговому APK.

`release.yml` (tag `v*`):

1. Полная сборка, подпись.
2. APK по ABI + universal + `SHA256SUMS`.
3. Source archive (MIT; полезно, хотя не обязательно).
4. GitHub Release (draft → publish).
5. Опционально: `fastlane`/страница релиза.

Кэш: Gradle, Flutter, `.pub-cache`.

### 17.4. Версионирование

- SemVer в `pubspec.yaml`; `versionCode` = номер сборки CI.
- Тег → имя релиза; changelog вручную.
- Обновления читают `releases/latest`; pre-release игнорируются.

---

## 18. Дорожная карта

| Этап | Содержание | Состояние |
|---|---|---|
| 0. Каркас | base-flutter, package, Drift, 4 таба, CI | ✅ сделано, тег `stage-0` |
| 1. Dart-ядро: крипто | AES-CTR/KDF, handshake, relay init, `MsgSplitter` | ✅ сделано, тег `stage-1` |
| 2. Dart-ядро: транспорт | Raw WS, WS-пул, CF-балансер, worker pool, TCP-fallback, stats | ✅ сделано, тег `stage-2` |
| 3. FakeTLS + Bot API | FakeTLS, локальный CONNECT 8081 | ✅ примитивы, тег `stage-3`; UI Bot API нет |
| 4. Relay-сервер | `ProxyServer`, bridge, re-encryption | ✅ сделано, тег `stage-4` |
| 5. Android-сервис | FGS, headless engine, каналы, DataStore, Keystore, tile, boot | ✅ сделано, тег `stage-5`; проверено на Android 16 |
| 6A. Settings parity | DC→IP, secret, Bot API, proxy protocol, import/export, диагностика | ⏳ в работе |
| 6B. Reliability | network restart, stall + TLS probe, auto-port, restart race | ⏳ не начато |
| 6C. Logs/updates | файловые логи, export, GitHub update | ⏳ не начато |
| 7. H2 media | порт `cf_h2`/`h2_transport`, replay, backpressure | ⏳ phase 2 |
| 8. Базовый слой | BasePage/BaseModel/ListModel из `34e5ba68`, рефакторинг экранов | ⏳ после 6A–6C |
| 9. iOS | отдельный трек, Network Extension | ⏳ план в §21.3 |

Android MVP уже работает: собственный CF-домен, TLS/порт 80, старт/стоп, фон, логи. До паритета с AndMTProto остаются 6A–6C и H2; точный список — §21.2.

---

## 19. Риски и открытые вопросы

| Риск | Влияние | Смягчение |
|---|---|---|
| MIT-совместимость | Нельзя потерять copyright Flowseal | `LICENSE`/`NOTICE`, заголовки в портированных файлах, source archive |
| Производительность Dart AES-CTR | Не хватит скорости на медиа/больших файлах | Бенчмарк ≥10 МБ/с, 64 КБ чанки, FFI-примитив только по gate |
| TLS-кривые (X25519) | Dart не даёт зафиксировать группу; DPI может рвать ClientHello | `no_secure`/порт 80, смена CF-домена, позже FFI-BoringSSL |
| H2 media | 998 строк логики, replay/backpressure; риск затянуть MVP | Phase 2, флаг выключен по умолчанию; WS-медиа-домен как fallback |
| Два FlutterEngine | +50–100 МБ PSS, риск OOM на слабых устройствах | `FlutterEngineGroup`, замер PSS, освобождение UI-engine в фоне |
| Headless engine | Не стартует/зависает после boot/OEM | ready-handshake, watchdog 15 с, максимум 3 рестарта, логи |
| Raw WS/FakeTLS порт | Тонкие баги кадров/парсинга | Тест-векторы, фаззинг парсеров, интеграция с фейковым DC |
| `bufferSizeKb` | Нельзя применить в Dart | Поле совместимости, скрыто в UI, задокументировано |
| CF Worker | Единая точка отказа/rate limit | Пул доменов, свой worker, TCP fallback |
| 16 KB | APK не ставится на новых устройствах | Проверка `libflutter.so`/APK в CI |
| `com.example` | Нельзя в Play, конфликты | Переименовать до релиза |
| Обновления вне Play | Пользователь должен разрешить установку | Инструкция, fallback на браузер |
| Права на base-flutter | Юридическая блокировка релиза | Подтвердить до публикации |
| OEM battery savers | Сервис убивают | Wakelock, инструкция по battery optimization, диагностика |
| Bot API | Клиент бота надо настроить на локальный прокси | Инструкция, проверка `curl`, понятная ошибка |

### Открытые вопросы

1. **GitHub owner/repo** для проверки обновлений и ссылки на исходники.
2. **Свой CF Worker** или публичные домены? Для стабильности рекомендуется свой (инструкция в `CfWorker.md`).
3. **Ключ подписи** и канал релизов (GitHub Releases / Telegram-канал).
4. **Иконка/имя** приложения (RU/EN).
5. **minSdk 29** оставляем или снижаем до 26?
6. **x86_64** в релизе или только для debug/эмулятора?
7. Публичный исходный репозиторий с первого дня или после стабилизации? (MIT не требует публичности.)
8. Подтверждены ли права на распространение `base-flutter` под MIT?
9. Принимаем ли **H2 media phase 2** (MVP без H2) или ждём полный паритет?
10. Принимаем ли ограничение **buffer size** (поле есть, эффекта нет)?
11. Достаточен ли gate **10 МБ/с** для AES-CTR, или сразу разрешаем FFI-примитив?
12. Bot API — в MVP или отдельным этапом после H2?

---

## 20. Что делать дальше

Android:

1. Закрыть 6A: DC→IP, показ/копирование/перегенерация секрета, Bot API switch+порт, proxy protocol, import/export, диагностика.
2. Закрыть 6B: network restart, stall detector + TLS/plain probe, auto-port, гонка `updateSettings`.
3. Закрыть 6C: файловые логи с ротацией, export/share, проверка обновлений GitHub.
4. H2 media — только если после 6A–6C медиа всё ещё медленное; WS-медиа уже работает.
5. Базовый слой `BasePage`/`BaseModel`/`ListModel` (коммит `34e5ba68`) — после функционала, без изменения поведения.

iOS — отдельный трек §21.3; начинать с i0 (loopback + Network Extension spike), не с UI.

---

## 21. Фактическое состояние и iOS

### 21.1. Android: что уже работает

- Чистое Dart-ядро `packages/tg_proxy_core`: MTProto handshake, AES-CTR, splitter, raw WS, CF proxy/worker, TCP fallback, FakeTLS, Bot API, relay bridge. 59 тестов.
- Kotlin FGS + headless `FlutterEngine` + `ProxyBridge`; DataStore, Keystore, уведомление, wakelock, QS tile, boot.
- Flutter UI: Connection, Settings, Workers, Logs (Talker), Info; собственный CF-домен `wts-tbss-test.ru` проверен: `101 Switching Protocols` и на 80, и на 443 (обязателен заголовок `Sec-WebSocket-Protocol: binary`).
- Старт/стоп, фон, переживание отсоединения UI; ping после устранения блокирующего direct WS — ~500 мс на тестовой сети.

### 21.2. Android: чего ещё нет

- DC→IP editor в UI; секрет: показать/копировать/перегенерировать; Bot API UI; proxy protocol; import/export JSON; диагностика/батарея.
- Network-change restart, stall detector + автоматический TLS/plain probe, auto-port при занятом 1443, гонка restart после `updateSettings`.
- Файловые логи/ротация/export; GitHub update check/download/install.
- H2 media (phase 2); `bufferSizeKb` — только совместимость.
- Базовый слой `BasePage`/`BaseModel`/`ListModel` (см. §7.6) — рефакторинг после 6A–6C.

### 21.3. iOS: отдельный трек

iOS не может "то же самое": нет foreground service, приложение в фоне засыпает через ~30 с. Варианты:

1. **Foreground-only** Flutter/Dart — работает только пока приложение открыто; 1–2 недели; для Telegram бесполезно.
2. **Network Extension** (`NEPacketTunnelProvider`) с платным Apple Developer — always-on, но relay должен быть на Swift/C: Flutter/Dart VM не влезает в лимит памяти extension. Ориентир 2–3 месяца; установка через Xcode/Ad Hoc, без App Store.
3. **Remote MTProto proxy** (VPS + mtg) + маленькое приложение-генератор ссылки — 1–2 дня, работает в фоне, но это не локальный прокси.

План i0–i5:

| Этап | Содержание | Оценка |
|---|---|---|
| i0 | Xcode app + `NEPacketTunnelProvider`, loopback `127.0.0.1:1443`, проверить, доходит ли Telegram iOS | 2–4 дня |
| i1 | Swift relay MVP: handshake/AES-CTR/splitter, WS к `kws*.wts-tbss-test.ru` 80/443, TCP fallback | 2–3 недели |
| i2 | `NETunnelProviderManager`, VPN profile, App Group, Keychain | 1 неделя |
| i3 | Flutter UI reuse: `ProxyRepository`, iOS channel, `tg://proxy`, логи | 1 неделя |
| i4 | Паритет: свой CF-домен, Worker, FakeTLS, DC→IP; H2 только при необходимости | 1–2 недели |
| i5 | Установка Xcode/Ad Hoc, продление provisioning раз в год | — |

Главный риск — сможет ли Telegram iOS подключиться к listener внутри Network Extension через loopback. Если i0 это не подтвердит, локальный вариант на iOS закрывается. Платный Apple Developer снимает блокер с entitlement, но не с памяти extension и не с ограничений ОС.
