# Project-specific R8/ProGuard rules.
#
# PayU's GPay integration references optional Google Pay India classes
# (com.google.android.apps.nbu.paisa.inapp.client.api.*) that are not
# packaged in standard app builds. During minification, R8 fails with
# missing-class errors unless these optional references are ignored.

-dontwarn com.google.android.apps.nbu.paisa.inapp.client.api.**
