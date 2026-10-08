import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two languages the app can display in — English (default) or
/// Filipino/Tagalog, switched from Profile's edit-profile card (see
/// ProfileScreen).
enum AppLocale { english, filipino }

/// App-wide language switch, a persisted singleton. YosApp listens to this
/// and rebuilds the whole tree on change, which is what makes every [t]
/// call anywhere in the app re-evaluate under the new language without
/// needing a restart.
class LocaleController extends ChangeNotifier {
  LocaleController._();
  static final LocaleController instance = LocaleController._();

  static const _prefsKey = 'app_locale';

  AppLocale _locale = AppLocale.english;
  AppLocale get locale => _locale;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _locale = prefs.getString(_prefsKey) == 'fil'
        ? AppLocale.filipino
        : AppLocale.english;
  }

  Future<void> setLocale(AppLocale value) async {
    if (_locale == value) return;
    _locale = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, value == AppLocale.filipino ? 'fil' : 'en');
  }
}

/// Returns [fil] when the app's language is set to Filipino, else [en] —
/// takes both strings inline at the call site rather than a central
/// key->translation map, so a screen adopting this stays self-contained
/// and obviously correct at a glance. Not reactive on its own; relies on
/// YosApp's top-level rebuild (see LocaleController's own doc) to
/// re-evaluate every call site when the language changes.
String t(String en, String fil) =>
    LocaleController.instance.locale == AppLocale.filipino ? fil : en;
