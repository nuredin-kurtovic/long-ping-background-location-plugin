# Long Ping example

A screen with tracking state, the last fix, an event log and a button for every command.

`integration_test/plugin_integration_test.dart` checks the bridge against the real engine (no permission needed).
`integration_test/tracking_test.dart` checks fixes, events, the queue and uploads end to end; see the top of the
file for the permission and GPS setup it needs.
