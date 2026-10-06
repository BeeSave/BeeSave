# BeeSave

Локальный учёт личных финансов для macOS 26 и новее, Apple Silicon. Бюджет и полные копии шифруются; обычный вход выполняется по паролю.

Стабильная версия: [1.2.0](https://github.com/BeeSave/BeeSave/releases/tag/v1.2.0). Предварительная проверка новых финансовых счетов: [1.3.0-rc.1](https://github.com/BeeSave/BeeSave/releases/tag/v1.3.0-rc.1), приложение 1.3.0/build 7.

В кандидате доступны депозитные ставки и сроки, прогноз дохода, кредитная задолженность и лимиты, ипотечные графики, подтверждение платежей, финансовый календарь и ручные банки. Каталог банков пока неполный и проверенных каталожных логотипов нет; сложные банковские правила и системные сценарии уведомлений ещё требуют проверки. Кандидат имеет статус Pre-release и не предлагается через стабильный механизм обновления.

## Установка

Скачайте BeeSave-macos-arm64.dmg из нужного выпуска, откройте образ и перенесите BeeSave в Applications. Перед испытанием 1.3.0 сохраните полную копию базы в 1.2.0. Новая версия переводит базу на схему 2; для возврата к 1.2.0 используйте исходную полную копию старой схемы.

## Сборка и проверка

Для ядра нужны Swift 6.2+ и macOS; для приложения — Xcode с SDK macOS 26+ и локальная Apple Development identity. Зависимости Argon2 и Sparkle закреплены в Vendor; сторонние лицензии включены в поставку.

```sh
swift test --scratch-path /private/tmp/BeeSaveTests --disable-sandbox
python3 scripts/generate_project.py
xcodebuild -project BeeSave.xcodeproj -scheme BeeSave -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /private/tmp/BeeSaveRelease build
```

UISmoke использует отдельную временную базу с вымышленными данными. Меню тестовых состояний доступно только в этой конфигурации и отсутствует в Release.

Упаковка кандидата с проверенными утилитами официального дистрибутива Sparkle 2.10.0:

```sh
python3 scripts/package_release.py '<signed BeeSave.app>' '<verified Sparkle bin>' \
  --pre-release --tag v1.3.0-rc.1 --output /private/tmp/BeeSavePreRelease
python3 scripts/verify_release.py /private/tmp/BeeSavePreRelease
python3 scripts/test_release_policy.py
```

Обычная упаковка стабильной версии требует полного банковского каталога. Предварительная упаковка требует явной метки и кандидатного тега; release-status.json указывает канал, версию, build и тег. DMG / feed подписываются ключом Sparkle из Связки ключей; приватный ключ не экспортируется. Публикация в GitHub Releases выполняется отдельно от упаковки.
