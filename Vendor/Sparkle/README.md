# Sparkle for BeeSave

Sparkle 2.10.0 is built from the exact upstream commit in `lock.json`. The
download archive is checked before extraction. Upstream is distributed under
its BSD license; the build retains `LICENSE` and framework license resources.

`network.patch` and `BeeSaveDownloadPolicy.h` enforce the approved BeeSave
network contract in the downloader: HTTPS release assets, redirects to the
two GitHub asset hosts, ephemeral sessions, 15/300 second timeouts, a 1 MiB
streaming feed limit, and a 200 MiB archive limit. The patch leaves Sparkle's
documented updater and installer APIs unchanged. The downloader XPC service
is excluded because the host already has the network client entitlement.

`package.patch` and `BeeSavePackagePolicy.h` require Ed25519 without an Apple
code signing fallback, then check the installed app's Apple Team, nested code,
runtime flags, entitlements, version/build, architecture, bundle identifier,
and permanent update key. The expected display version accompanies Sparkle's
existing installation input across its private XPC protocol. New versions
cannot silently change the app's access rights or disable Library Validation.

The framework and every nested executable are signed with the app's Apple
Development identity before Xcode embeds and signs the framework. Library
Validation, App Sandbox, and Hardened Runtime remain enabled.

The test-only URLProtocol injection is compiled only by the downloader test
runner. It is absent from the framework used by BeeSave.
