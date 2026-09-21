class AppSettings {
  /// When true, HomeScreen auto-opens RemoteScreen once (on cold launch,
  /// right after a speaker is actually connected - never before, so a
  /// fresh install/no-speaker-yet case still lands on the normal speaker
  /// scan first) instead of sitting on the Player page. See
  /// HomeScreen._maybeAutoOpenRemote.
  final bool openRemoteByDefault;

  /// Index into RemoteScreen's own `_layouts` list (0 = remotev1, 1 =
  /// remotev2) - whichever design was last picked via its Design 1/Design 2
  /// chips, remembered independently of [openRemoteByDefault] (that toggle
  /// only decides WHETHER to land on Remote at all, not which design shows
  /// once there). Not range-checked here - RemoteScreen clamps it against
  /// its own layout count so an old saved value never indexes out of range
  /// if a design is ever removed.
  final int lastRemoteDesignIndex;

  const AppSettings({this.openRemoteByDefault = false, this.lastRemoteDesignIndex = 0});

  AppSettings copyWith({bool? openRemoteByDefault, int? lastRemoteDesignIndex}) => AppSettings(
        openRemoteByDefault: openRemoteByDefault ?? this.openRemoteByDefault,
        lastRemoteDesignIndex: lastRemoteDesignIndex ?? this.lastRemoteDesignIndex,
      );
}
