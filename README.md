# BatteryWidget — заряд устройств

Виджет для iOS 26 и macOS 26 в стиле Liquid Glass. Показывает заряд Mac, iPhone,
наушников и других известных устройств. В маленьком виджете используется
системная сетка 2×2, в среднем — четыре кольца в ряд: свободные ячейки
остаются пустыми серыми кольцами, как в виджете «Аккумуляторы». В приложении и
popover ряд остаётся динамическим, без пустых колонок. Large-виджет показывает
полный вертикальный список всех устройств. Порядок: локальное устройство
первым, затем Mac, наушники, iPhone, Apple Watch и остальные. В large длинное
имя устройства обрезается, а процент заряда и иконка батареи всегда видны
целиком.

Кольца используют угловой градиент: тёмный конец в начале дуги и светлый — у
отметки текущего заряда. На 100 % градиент замыкается симметрично, без тёмного
шва сверху. Сейчас `containerBackground` виджета — `Color.clear`; WidgetKit на
iPhone и Mac может заменить его системной подложкой. Полностью прозрачный фон
стороннего виджета WidgetKit не поддерживает.

Синхронизация идёт через **iCloud Keychain** (synchronisable Keychain Sharing),
а в одной локальной сети дополнительно работает **Bonjour**. Это позволяет
обновлять заряд быстро, даже если устройства находятся в разных сетях.

---

## Возможности

- **iOS App** — карточка Liquid Glass с динамическим рядом устройств.
- **iOS Widget** — small (2×2 с пустыми слотами), medium (четыре кольца, пустые слоты) и large (список всех устройств).
- **macOS Menu Bar** — иконка с зарядом Mac и popover с вложенной стеклянной карточкой.
- **macOS Widget** — те же три размера и те же общие view, что и на iPhone: small 2×2, medium 4 кольца, large со списком.
- **Фон** — `Color.clear` в `containerBackground`; WidgetKit может подставить системную подложку, полностью прозрачный фон недоступен.
- **Градиент колец** — угловой: светлый конец у отметки заряда; 100 % замыкается без шва.
- **Синхронизация**:
  - synchronisable Keychain — через один iCloud-аккаунт и общий keychain group;
  - Bonjour — быстрый обмен по Wi-Fi или через режим модема iPhone.
- **Локальный кэш** — отдельный non-synchronisable Keychain item, который видят
  приложение и виджет на одном устройстве. На macOS он используется как основной
  кэш, потому что контейнер App Group с бесплатным Personal Team может быть
  недоступен для записи.

## Что показывается

- Mac — заряд локального Mac;
- наушники — если устройство передало заряд;
- iPhone — заряд iPhone, вошедшего в тот же iCloud;
- Apple Watch и другие устройства — если для них есть данные.

Показывается по одному актуальному устройству каждого типа; старые записи с
другими UUID отбрасываются. В small- и medium-виджетах свободные ячейки
остаются пустыми кольцами, как в системном виджете; large показывает полный
вертикальный список устройств с иконками, процентами и батарейками.

## Наушники через Mac

Если iPhone не отдаёт заряд классических наушников (например, Redmi Buds 5),
его может прочитать Mac и передать на iPhone через iCloud Keychain:

1. На Mac откройте BatteryMacApp и разрешите доступ к Bluetooth, если система
   спросит.
2. Подключите наушники к Mac в **Системные настройки → Bluetooth**. Если они
   одновременно подключены к iPhone, нужен режим multipoint; иначе на время
   обновления отключите их от iPhone.
3. Нажмите кнопку обновления в меню BatteryMacApp или подождите до минуты.
   Приложение читает `system_profiler SPBluetoothDataType`, а как fallback —
   приватные battery-геттеры `IOBluetoothDevice`.
4. Значение публикуется в общий iCloud Keychain и появляется в iPhone-виджете.
   Последняя запись хранится до 24 часов.

Пока наушники подключены только к iPhone, Mac их не видит и обновить заряд не
может. Mac-приложение должно быть запущено; iCloud Keychain должен быть включён
на обоих устройствах.

## Структура

```
BatteryWidget/
├── Shared/
│   ├── BatteryData.swift          — модели устройств и правила свежести
│   ├── BatteryColors.swift        — кольца, стекло, динамическая панель
│   ├── BatteryStore.swift         — App Group/Keychain-кэш и transport
│   ├── BatterySyncManager.swift   — объединение Bonjour + Keychain
│   ├── BonjourSyncManager.swift   — локальная сеть
│   └── IOKitBatteryReader.swift   — заряд Mac
├── iOSApp/
├── iOSWidget/
├── macOSApp/
├── macOSWidget/
├── project.yml                    — спецификация XcodeGen
└── setup.sh
```

## Настройка шаблона

Этот репозиторий задуман как универсальный черновик. Перед первой сборкой
замените placeholder-префикс и выберите свою команду:

1. Задайте свой reverse-DNS префикс одной командой:
   ```bash
   ./scripts/configure.sh com.yourprefix
   ```
   Либо вручную измените `BUNDLE_ID_PREFIX` в `project.yml`. Один префикс
   используется для bundle ID, App Group и Keychain access group.
2. Выберите свою Team в Xcode для всех четырёх targets. Team ID не нужно
   записывать в репозиторий — его можно передавать в `xcodebuild` через
   `DEVELOPMENT_TEAM=...`.
3. Если вы меняете `BUNDLE_ID_PREFIX` после установки приложения, старые
   Keychain/App Group данные не перенесутся: это уже другое приложение.

Перед коммитом проверяйте, что в репозиторий не попали личные данные:

```bash
./scripts/check-personal-data.sh
```

В репозитории есть `.gitignore` для `xcuserdata`, `DerivedData`, `.env` и
файлов сертификатов. При желании включите локальный pre-commit hook:

```bash
git config core.hooksPath .githooks
```

## Сборка

```bash
brew install xcodegen
xcodegen generate
open BatteryWidget.xcodeproj
```

Или:

```bash
./setup.sh
```

Проверенная сборка из терминала:

```bash
# macOS
xcodebuild -project BatteryWidget.xcodeproj \
  -scheme BatteryMacApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID CODE_SIGN_STYLE=Automatic build

# iOS (физическое устройство)
xcodebuild -project BatteryWidget.xcodeproj \
  -scheme BatteryWidgetApp -configuration Debug \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID CODE_SIGN_STYLE=Automatic build
```

### Xcode

1. Откройте проект и выберите свою Team для всех четырёх targets.
2. Включите **Keychain Sharing** с группой
   `$(AppIdentifierPrefix)com.example.batterywidget.shared`.
3. Для iOS включите **App Groups** с
   `group.com.example.batterywidget`.
4. На macOS с бесплатным Personal Team App Group может не попасть в
   provisioning profile. Это не блокирует приложение: локальный кэш идёт через
   Keychain. Если у вас платный аккаунт, можно дополнительно включить App Group
   для обоих macOS targets.
5. Для проверки синхронизации на обоих устройствах должен быть включён
   **iCloud Keychain** и выполнен вход в один и тот же Apple ID.

### Установка на iPhone без Xcode UI

Если iPhone уже подключён, доверен и на нём включён Developer Mode:

```bash
# 1. Собрать под конкретный iPhone
xcodebuild -project BatteryWidget.xcodeproj \
  -scheme BatteryWidgetApp -configuration Debug \
  -destination 'id=UDID_IPHONE' \
  -derivedDataPath /tmp/BatteryWidgetDerived \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID CODE_SIGN_STYLE=Automatic build

# 2. Установить и запустить
xcrun devicectl device install app \
  --device UDID_IPHONE \
  /tmp/BatteryWidgetDerived/Build/Products/Debug-iphoneos/BatteryWidgetApp.app
xcrun devicectl device process launch \
  --device UDID_IPHONE com.example.batterywidget
```

На iPhone: **Долгое нажатие на рабочий стол → Изменить → Добавить виджет →
Аккумуляторы**. Если приложение не открывается, разрешите разработчика в
**Настройки → Основные → VPN и управление устройством**; Developer Mode
включается в **Настройки → Конфиденциальность и безопасность**.

### Если на macOS не появился large

WidgetKit кэширует список поддерживаемых размеров. В проекте версия виджета
поднята до `1.1 (2)`. После пересборки удалите старый экземпляр виджета,
перезапустите приложение и снова откройте галерею виджетов. Если галерея
всё ещё показывает только small/medium, очистите кэш дескрипторов:

```bash
# завершить chronod, удалить descriptor только для BatteryWidget и открыть приложение заново
killall chronod
sqlite3 "$HOME/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql" \
  "DELETE FROM Descriptors WHERE bundleIdentifier LIKE '%batterywidget%';"
open "<путь к BatteryMacApp.app>"
```

Если виджеты всё ещё выглядят плотными, проверьте в macOS:
**Системные настройки → Рабочий стол и Dock → Виджеты → Затемнять виджеты на
рабочем столе** — поставьте «Никогда». Этот системный режим затемняет любой
виджет, включая полупрозрачный.

## Требования

- iOS 26+ на iPhone;
- macOS 26+ на Mac;
- Xcode с iOS 26 SDK (Xcode 26/27);
- физические устройства для проверки Keychain/iCloud-синхронизации;
- один Apple ID и включённый iCloud Keychain на Mac и iPhone.

Симулятор не обязателен. Если Xcode просит более новый iOS Simulator runtime —
это отдельный компонент, не Swift-пакет; для сборки на физический iPhone он не
нужен.

## Ограничения

- Сторонние наушники (например, Redmi Buds) не отдают заряд на iPhone через
  публичный API. Mac может прочитать его, только когда наушники подключены к
  Mac, и передать значение через iCloud Keychain. Приватные геттеры
  `IOBluetoothDevice` не стоит использовать в App Store-сборке.
- Системный виджет «Аккумуляторы» использует приватные источники данных
  (Always-On, Find My, некоторые Bluetooth-аксессуары). Полное повторение
  списка всех аксессуаров сторонним приложением невозможно.
- iCloud capability на бесплатном Personal Team недоступна; поэтому
  синхронизация построена на Keychain Sharing, а не на CloudKit.
- App Group на macOS с Personal Team может быть недоступен для записи; это
  обработано fallback-кэшем в Keychain.
