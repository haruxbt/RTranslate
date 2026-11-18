#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Requires the app-owned VOICEVOX adapter to be ready at 127.0.0.1:50022.
# The probe plays synthetic speech silently (volume 0), without saving media.
mkdir -p work/voice-queue-check
swiftc -emit-library -emit-module -module-name WebinarCore Sources/WebinarCore/*.swift -o work/voice-queue-check/libWebinarCore.dylib -emit-module-path work/voice-queue-check/WebinarCore.swiftmodule
swiftc -parse-as-library -I work/voice-queue-check -L work/voice-queue-check -lWebinarCore -Xlinker -rpath -Xlinker "$PWD/work/voice-queue-check" "${VOICE_QUEUE_SOURCE:-Sources/WebinarNihongo/VoiceQueue.swift}" Sources/WebinarNihongo/VoicevoxService.swift Tests/Integration/VoiceQueueProbe.swift -o work/voice-queue-check/probe
work/voice-queue-check/probe
