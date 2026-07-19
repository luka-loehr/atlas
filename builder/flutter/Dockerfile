# atlas-flutter-builder — Flutter + Android SDK for building APKs/AABs.
#
# Built on the cirruslabs image, which ships the Flutter SDK, the Android SDK
# (cmdline-tools, platform, build-tools) and pre-accepted licenses — building
# that stack from scratch would be gigabytes of fragile setup. We only pin the
# channel. The Gradle/pub caches live in the synced build dir on atlas (build/
# is excluded from the Mac sync), so warm APK builds skip the cold download.
FROM ghcr.io/cirruslabs/flutter:stable

LABEL org.opencontainers.image.title="atlas-flutter-builder"
