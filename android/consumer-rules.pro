# Applied to every app that uses Long Ping and shrinks its release build with R8.

# WorkManager (the restart watchdog) creates its Room database by reflection through the no-argument
# constructor of WorkDatabase_Impl. Room 2.6's own rule keeps the class but not that constructor, and R8's full
# mode (the default since AGP 8) then removes it: the app crashes at launch with
# "NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []".
-keep class * extends androidx.room.RoomDatabase { <init>(); }
