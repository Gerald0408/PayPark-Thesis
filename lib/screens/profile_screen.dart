import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/collector.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/toast.dart';
import 'collectors_screen.dart';

/// The "Profile" tab in RootShell's bottom navigation — the signed-in
/// collector's own account details (name, username, role, registered
/// date — exactly what was captured at registration), plus Collectors
/// (admin-only), the in-app admin's user-management screen. Self-service
/// "Change password" and "Face ID" screens used to live here too, but
/// with a real in-app admin now able to reset any account from
/// CollectorsScreen, they were dropped as redundant — a locked-out or
/// re-enrolling collector just asks the admin instead. Printer has its
/// own bottom-nav tab now (see RootShell), and Log out lives one level up
/// too (its own bottom-nav action, see RootShell._confirmLogout).
///
/// The account card itself IS self-service, though: tapping it opens an
/// inline edit for name/phone/birthday — the same plain details captured
/// at registration, nothing account-recovery-relevant (username, role,
/// and any actual reset stay admin-only, see CollectorsScreen).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Deliberately NOT const: RootShell's IndexedStack gives ProfileScreen
    // itself a fresh (non-const) instance on every rebuild now (see its own
    // comment on why), specifically so the dark/light toggle actually
    // reaches this subtree instead of being skipped by Flutter's
    // identical-widget shortcut. Returning a `const _ProfileBody()` here
    // reintroduced the exact same shortcut one level down: it's the same
    // canonicalized instance every time, so `_ProfileBody`'s own Element
    // never got marked dirty from this rebuild, and the toggle never
    // reached the Scaffold/StreamBuilder/YosColors reads inside it — this
    // screen stayed on light-mode colors no matter how many times you
    // toggled. A plain (non-const) instance goes through the normal
    // update path instead, so it always re-reads the current colors.
    return _ProfileBody();
  }
}

/// Split out from [ProfileScreen] purely so [currentCollectorProfile]'s
/// stream can be grabbed exactly once, in [State.initState] — see that
/// getter's own "fresh Stream per call, cache it yourself" doc comment.
/// Calling it directly as a StreamBuilder's `stream:` argument (the
/// previous shape of this screen) hands StreamBuilder a brand-new Stream
/// on every rebuild, which is exactly what causes Flutter's
/// "'_dependents.isEmpty': is not true" crash — the same pitfall
/// FeesScreen and RfidPointsScreen already avoid with this identical
/// `late final` pattern.
class _ProfileBody extends StatefulWidget {
  const _ProfileBody();

  @override
  State<_ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends State<_ProfileBody> {
  late final Stream<Collector?> _profile =
      YosRepository.instance.currentCollectorProfile;

  /// Whether this account is the Super Admin — for the role pill.
  bool _isSuperAdmin = false;
  StreamSubscription<bool>? _superSub;

  bool _editing = false;
  bool _saving = false;
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _birthdayText = TextEditingController();
  DateTime? _birthday;

  // Snapshotted alongside the controllers in _startEdit, purely so _isDirty
  // has something to compare the live field values against — without this,
  // Save would have no way to tell "the collector typed something" apart
  // from "these are still the values that loaded".
  String _originalName = '';
  String _originalPhone = '';
  String _originalBirthdayText = '';

  /// Staged language choice — only actually applied (see [_save]) once
  /// Save changes is tapped, not the moment a chip is picked. Switching
  /// LocaleController immediately would re-translate the entire app —
  /// this very card, mid-edit, included — out from under the collector
  /// before they've confirmed anything, which read as confusing rather
  /// than responsive. Null only before the first [_startEdit].
  AppLocale? _pendingLocale;

  @override
  void initState() {
    super.initState();
    // Re-evaluate _isDirty (and therefore the Save button's enabled state)
    // on every keystroke — TextEditingController doesn't rebuild its
    // listeners on its own.
    _name.addListener(_onFieldChanged);
    _phone.addListener(_onFieldChanged);
    _superSub = YosRepository.instance.currentUserIsSuperAdmin.listen(
      (v) {
        if (mounted) setState(() => _isSuperAdmin = v);
      },
      onError: (Object e) => debugPrint('superAdmin error (ignored): $e'),
    );
  }

  void _onFieldChanged() {
    if (_editing) setState(() {});
  }

  @override
  void dispose() {
    _superSub?.cancel();
    _name.dispose();
    _phone.dispose();
    _birthdayText.dispose();
    super.dispose();
  }

  bool get _isDirty =>
      _name.text.trim() != _originalName ||
      _phone.text.trim() != _originalPhone ||
      _birthdayText.text != _originalBirthdayText ||
      _pendingLocale != LocaleController.instance.locale;

  // Controllers are only ever populated from a live [Collector] snapshot
  // right when edit mode starts — not re-synced on every rebuild while
  // editing, or the collector's own in-progress keystrokes would keep
  // getting clobbered by the stream's next emission of the still-old
  // (unsaved) doc.
  void _startEdit(Collector me) {
    _name.text = me.name;
    _phone.text = me.phone ?? '';
    _birthday = me.birthday;
    _birthdayText.text = me.birthday == null
        ? ''
        : DateFormat('MM/dd/yyyy').format(me.birthday!);
    _originalName = _name.text.trim();
    _originalPhone = _phone.text.trim();
    _originalBirthdayText = _birthdayText.text;
    _pendingLocale = LocaleController.instance.locale;
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _pendingLocale = null;
    });
  }

  Future<void> _pickBirthday() async {
    var temp = _birthday ?? DateTime(DateTime.now().year - 25, 1, 1);
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: YosColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(t('Cancel', 'Kanselahin')),
                  ),
                  Text(t('Birthday', 'Kaarawan'),
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(temp),
                    child: Text(t('Done', 'Tapos')),
                  ),
                ],
              ),
              SizedBox(
                height: 216,
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: temp,
                  minimumYear: 1930,
                  maximumDate: DateTime.now(),
                  onDateTimeChanged: (d) => temp = d,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _birthday = picked;
      _birthdayText.text = DateFormat('MM/dd/yyyy').format(picked);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await YosRepository.instance.updateOwnProfile(
        name: _name.text.trim(),
        phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        birthday: _birthday,
      );
      // Committed only now, alongside everything else Save writes — see
      // _pendingLocale's own doc comment for why this doesn't happen the
      // moment a chip is tapped. This is what actually re-translates the
      // rest of the app (via YosApp's top-level rebuild — see
      // LocaleController's doc comment), so it's deliberately the last
      // thing this method does before the success toast, which then
      // renders in whichever language just took effect.
      final locale = _pendingLocale;
      if (locale != null && locale != LocaleController.instance.locale) {
        await LocaleController.instance.setLocale(locale);
      }
      if (!mounted) return;
      Toast.success(context, t('Profile updated', 'Na-update ang Profile'));
      setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        Toast.error(context,
            t("Couldn't save changes — try again.", 'Hindi na-save ang mga pagbabago — subukan ulit.'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Only stages the choice locally (see [_pendingLocale]'s doc comment) —
  /// the actual app-wide switch happens in [_save].
  void _selectLocale(AppLocale locale) {
    setState(() => _pendingLocale = locale);
  }

  /// Shared avatar circle — a photo (once [Collector.photoUrl] is set) or
  /// a generic person icon otherwise. No self-service edit here: profile photo uploads
  /// depended on Firebase Storage, which isn't set up for this project, so
  /// the avatar is display-only until/unless that's provisioned.
  Widget _avatar(Collector me, {required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: YosColors.accentDeep,
        borderRadius: BorderRadius.circular(size * 0.32),
        image: me.photoUrl == null
            ? null
            : DecorationImage(
                image: NetworkImage(me.photoUrl!), fit: BoxFit.cover),
      ),
      alignment: Alignment.center,
      child: me.photoUrl != null
          ? null
          : Icon(Icons.person_rounded,
              size: size * 0.6, color: YosColors.onAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(t('Profile', 'Profile'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<Collector?>(
            stream: _profile,
            builder: (context, snap) {
              final me = snap.data;
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (snap.hasError)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Column(
                        children: [
                          const Icon(Icons.error_outline_rounded,
                              size: 40, color: YosColors.bad),
                          const SizedBox(height: 12),
                          Text(
                              t("Couldn't load your profile: ${snap.error}",
                                  'Hindi ma-load ang iyong profile: ${snap.error}'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: YosColors.sub,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    )
                  else if (me == null)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                          child:
                              CircularProgressIndicator(color: YosColors.ink)),
                    )
                  else if (_editing)
                    PopIn(child: _buildEditCard(me))
                  else
                    PopIn(child: _buildReadCard(context, me)),
                  // Collectors is admin-only — skip it for a regular
                  // collector instead of showing an empty white box.
                  if (!_editing && me?.isAdmin == true) ...[
                    const SizedBox(height: 14),
                    PopIn(
                      delayMs: 90,
                      child: GlassCard(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          leading:
                              Icon(Icons.groups_rounded, color: YosColors.ink),
                          title: Text(t('Collectors', 'Mga Kolektor'),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const CollectorsScreen())),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Full-detail read view — every plain account field on its own clearly
  /// labeled row (name, role, phone, birthday, registered date), the same
  /// label/value shape VehicleDetailScreen's _DetailRow already uses
  /// elsewhere in the app, rather than the previous cramped stack of small
  /// icon+text lines. The whole card still opens edit mode on tap (see
  /// [_startEdit]) — this only changes how the read-only view presents
  /// what's already there.
  Widget _buildReadCard(BuildContext context, Collector me) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _startEdit(me),
        child: GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _avatar(me, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(me.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 18)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          // Same amber/gold accentDeep pill for both roles —
                          // see the avatar above for why this dropped the
                          // separate mint/seafoam Collector tint.
                          decoration: BoxDecoration(
                              color: YosColors.accentDeep,
                              borderRadius: BorderRadius.circular(999)),
                          child: Text(
                              _isSuperAdmin
                                  ? t('Super Admin', 'Super Admin')
                                  : me.isAdmin
                                      ? t('Admin', 'Tagapangasiwa')
                                      : t('Collector', 'Kolektor'),
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: YosColors.onAccent)),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.edit_rounded, color: YosColors.sub, size: 18),
                ],
              ),
              const SizedBox(height: 18),
              Divider(height: 1, color: YosColors.glassBorder),
              const SizedBox(height: 16),
              _profileDetailRow(t('Full Name', 'Buong Pangalan'), me.name),
              _profileDetailRow(
                  t('Phone', 'Telepono'), me.phone ?? '—'),
              _profileDetailRow(
                  t('Birthday', 'Kaarawan'),
                  me.birthday == null
                      ? '—'
                      : DateFormat('MMM d, y').format(me.birthday!)),
              _profileDetailRow(
                  t('Registered', 'Petsa ng Pagrehistro'),
                  DateFormat('MMM d, y').format(me.createdAt),
                  last: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileDetailRow(String label, String value, {bool last = false}) =>
      Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: TextStyle(
                      color: YosColors.sub,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );

  Widget _buildEditCard(Collector me) {
    return GlassCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: _avatar(me, size: 72)),
            const SizedBox(height: 16),
            Text(t('Edit Profile', 'I-edit ang Profile'),
                style: TextStyle(
                    color: YosColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 18)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration:
                  InputDecoration(labelText: t('Full Name', 'Buong Pangalan')),
              validator: (v) => (v == null || v.trim().length < 2)
                  ? t('Enter your full name', 'Ilagay ang buong pangalan')
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                  labelText: t('Phone number', 'Numero ng Telepono')),
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                if (digits.isEmpty) return null;
                return digits.length < 10
                    ? t('Enter a valid phone number',
                        'Ilagay ang wastong numero ng telepono')
                    : null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _birthdayText,
              readOnly: true,
              onTap: _pickBirthday,
              decoration: InputDecoration(
                  labelText: t('Birthday', 'Kaarawan'),
                  hintText: 'MM/DD/YYYY'),
            ),
            const SizedBox(height: 20),
            Text(t('Language', 'Wika'),
                style: TextStyle(
                    color: YosColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('English'),
                  selected: _pendingLocale == AppLocale.english,
                  onSelected: (_) => _selectLocale(AppLocale.english),
                ),
                ChoiceChip(
                  label: const Text('Filipino'),
                  selected: _pendingLocale == AppLocale.filipino,
                  onSelected: (_) => _selectLocale(AppLocale.filipino),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              // Both Expanded (equal share), not just Save — Cancel used
              // to size to its own bare text, which was fine for "Cancel"
              // but left Save's Expanded share to absorb all the extra
              // length of a longer translated label ("Kanselahin" /
              // "I-save ang mga Pagbabago") on its own. Each label is also
              // wrapped in a FittedBox below so it shrinks to fit its own
              // button instead of wrapping or overflowing.
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : _cancelEdit,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 16),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(t('Cancel', 'Kanselahin'), maxLines: 1),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Material(
                    // Faded + inert until something's actually changed —
                    // otherwise Save sat there fully "live" for an edit
                    // that would just write back the same values it
                    // loaded.
                    color: (_saving || _isDirty)
                        ? YosColors.accent
                        : YosColors.accent.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      onTap: (_saving || !_isDirty) ? null : _save,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 8),
                        alignment: Alignment.center,
                        child: _saving
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: YosColors.onAccent),
                              )
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                    t('Save changes', 'I-save ang mga Pagbabago'),
                                    maxLines: 1,
                                    style: TextStyle(
                                        color: YosColors.onAccent,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15)),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
