# BeeSave

Local-first budgeting and savings for Apple Silicon Macs running macOS 26.0 or later.

BeeSave 1.8 shows compact Liquid Glass exchange rates beside the Home filters. USD and GBP are shown by default, excluding your base currency; choose up to five currencies in Settings → Currencies and Rates. Standard Home summaries use your base currency, and account balances also show their original currency.

BeeSave brings your accounts, income, expenses, transfers, budgets, and reports together in one place. It supports multiple currencies, CSV import and export, encrypted storage, and full backups.

## Install

Download a ready-to-use version from [GitHub Releases](https://github.com/BeeSave/BeeSave/releases/latest). Before replacing an existing installation, save a full backup of your budget and quit BeeSave. Open the supplied DMG, or extract the ZIP, and move `BeeSave.app` to your Applications folder.

## Build

Open `BeeSave.xcodeproj` in Xcode, select the `BeeSave` scheme, and build for macOS. Configure signing for your own Apple Development team.

To check the core and presentation packages:

```sh
swift test
```

Application sources are in `App/`, the accounting core is in `Sources/BudgetCore/`, and presentation code is in `Sources/BudgetPresentation/`. Dependencies and their licenses are in `Vendor/`; third-party notices are in `App/Resources/ThirdPartyNotices.txt`.
