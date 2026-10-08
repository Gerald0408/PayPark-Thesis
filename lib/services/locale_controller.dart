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

  /// Whether a language was ever picked on this phone (or set by
  /// [preferForCollector]) — a collector's Filipino default only applies
  /// when it wasn't.
  bool _chosen = false;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    _chosen = saved != null;
    _locale = saved == 'fil' ? AppLocale.filipino : AppLocale.english;
  }

  /// Collectors default to Filipino — only on a phone where no language
  /// was chosen yet, so anyone who picked English keeps it.
  Future<void> preferForCollector() async {
    if (_chosen) return;
    await setLocale(AppLocale.filipino);
  }

  Future<void> setLocale(AppLocale value) async {
    _chosen = true;
    if (_locale == value) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value == AppLocale.filipino ? 'fil' : 'en');
      return;
    }
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
