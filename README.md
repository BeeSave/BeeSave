# BeeSave

Local-first budgeting and savings for Apple Silicon Macs running macOS 26.0 or later.

BeeSave 1.9 adds financial planning and projects. Plan regular income, living costs, obligations, savings, and major spending across upcoming periods. Explore mortgage prepayments, renovation budgets, and small-business projects with local participants. Russian personal income tax and deduction estimates cover supported cases for 2025 and 2026.

Account reconciliation can record a balance difference as one income or expense, or as a neutral adjustment. Switch accounts between lists and cards. Home separates upcoming payments from useful reminders and shows actual and forecast income and expenses.

Plans never create paid transactions automatically. Confirm a payment or link an existing transaction to account for it once. Forecasts show missing amounts or exchange rates, and conditional tax refunds do not cover obligations in the conservative plan. Country rules and contract terms are separate; unsupported taxes require a manual estimate.

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
