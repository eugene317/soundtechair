package com.airstaffs.soundtechair

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service needs to own this Activity's FlutterEngine (reused by its
// foreground service, not recreated) - see SoundTouchAudioHandler's doc
// comment for why. AudioServiceActivity already extends FlutterActivity.
//
// No local_volume platform channel here anymore - see
// SoundTouchAudioHandler's doc comment for why the remote-volume-session
// approach that needed it was abandoned (2026-07-23): hardware volume
// buttons reaching the speaker is avoided simply by never declaring a
// remote/absolute volume session in the first place, so there is nothing
// left for this Activity to forward.
class MainActivity : AudioServiceActivity()
