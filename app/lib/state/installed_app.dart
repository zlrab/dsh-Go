import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../update/installer.dart';

/// What Android reports about the installed build: versionName, versionCode, the ABI
/// this APK was built for and the free space downloads can use.
///
/// The self-update flow that used to own this data is removed in this fork (our
/// package name and signing key differ from upstream's, so its releases can never
/// install here). Two things still need it: 关于 shows the installed version, and
/// the workshop checks free space before unpacking a resource pack.
final installedAppProvider = FutureProvider<InstalledApp>(
  (ref) => const ChannelUpdateInstaller().installedApp(),
);
