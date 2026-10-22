# Puts the Android toolchain kept in .devtools/ on PATH:  source scripts/android_env.sh
_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export JAVA_HOME="$(ls -d "$_root"/.devtools/jdk/jdk-17*/Contents/Home | head -1)"
export ANDROID_HOME="$_root/.devtools/android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$(ls -d "$_root"/.devtools/gradle-*/bin | head -1):$PATH"
unset _root
