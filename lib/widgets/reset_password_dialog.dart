import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/auth_errors.dart';
import '../core/theme.dart';
import '../core/username.dart';
import '../models/access_request.dart';
import '../models/collector.dart';
import '../services/firestore_service.dart';
import 'toast.dart';

/// Admin-driven "reset access" flow for a locked-out collector — shows a
/// form pre-filled with [collector]'s known details, auto-generates a new
/// username (see [_ResetPasswordDialogState._generateUsername] — their
/// old one can't be reused), and lets the admin dictate a passcode, then
/// calls YosRepository.resetCollectorPassword. Returns the new username if the
/// reset actually completed, null if the admin cancelled — the caller
/// needs that username to record on a resolved AccessRequest (see
/// [grantAccessRequestReset]) so the waiting collector's own screen knows
/// which account to offer a passcode field for. Shared between
/// AccessRequestsScreen's "Grant password reset" and CollectorsScreen's
/// own reset action, so both stay in sync.
Future<String?> showResetCollectorPasswordDialog(
  BuildContext context,
  Collector collector,
) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ResetPasswordDialog(collector: collector),
  );
}

/// Full "grant this request" flow for an [AccessRequest] — an access
/// request is just a typed name with no verified identity behind it (see
/// AccessRequest's class doc), so the admin has to say *which real
/// collector* this actually is first (see [CollectorPickerDialog],
/// pre-filled with the request's typed name) before
/// [showResetCollectorPasswordDialog] can run against a real account.
/// Resolves the request afterward so it drops off the pending list.
/// Shared between AccessRequestsScreen's per-row action and the
/// dashboard's own pending-resets notification, so both stay in sync.
Future<void> grantAccessRequestReset(
    BuildContext context, AccessRequest request) async {
  final all = await YosRepository.instance.allCollectors().first;
  if (!context.mounted) return;
  final picked = await showDialog<Collector>(
    context: context,
    builder: (_) =>
        CollectorPickerDialog(all: all, initialQuery: request.name),
  );
  if (picked == null || !context.mounted) return;

  final newUsername = await showResetCollectorPasswordDialog(context, picked);
  if (newUsername == null || !context.mounted) return;

  try {
    await YosRepository.instance
        .resolveAccessRequest(request.id, newUsername: newUsername);
  } catch (e) {
    if (context.mounted) {
      Toast.error(
          context, 'Reset succeeded, but couldn\'t clear the request: $e');
    }
  }
}

/// Searchable "which collector is this?" picker — pre-fills the search box
/// with an access request's typed name (a starting guess, not a filter
/// that can hide the right person if it doesn't quite match) and always
/// lists the full roster underneath, live-filtered as you type. Tapping
/// any row pops the dialog with that [Collector].
class CollectorPickerDialog extends StatefulWidget {
  const CollectorPickerDialog({super.key, required this.all, required this.initialQuery});

  final List<Collector> all;
  final String initialQuery;

  @override
  State<CollectorPickerDialog> createState() => _CollectorPickerDialogState();
}

class _CollectorPickerDialogState extends State<CollectorPickerDialog> {
  late final _search = TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.all
        : widget.all
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                c.username.toLowerCase().contains(q))
            .toList();
    return AlertDialog(
      title: const Text('Which collector is this?'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search name or username',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: filtered.isEmpty
                  ? const Center(child: Text('No matches.'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        return ListTile(
                          title: Text(c.name),
                          subtitle: Text('@${c.username}'),
                          onTap: () => Navigator.pop(context, c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({required this.collector});
  final Collector collector;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.collector.name);
  late final _phone = TextEditingController(text: widget.collector.phone ?? '');
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _birthdayText = TextEditingController();

  DateTime? _birthday;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _birthday = widget.collector.birthday;
    if (_birthday != null) {
      _birthdayText.text = DateFormat('MM/dd/yyyy').format(_birthday!);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _birthdayText.dispose();
    super.dispose();
  }

  Future<void> _pickBirthday() async {
    var temp = _birthday ?? DateTime(DateTime.now().year - 25, 1, 1);
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    child: const Text('Cancel'),
                  ),
                  const Text('Birthday',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(temp),
                    child: const Text('Done'),
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

  /// A fresh username derived from [name] — the admin no longer picks one
  /// by hand (their old one can't be reused, see resetCollectorPassword's
  /// class doc, so there was never a meaningful choice to make here
  /// anyway). Lowercased letters/digits from the name plus a random
  /// 4-digit suffix keep it comfortably unique and under
  /// normalizeUsername's 20-character cap; [_submit] regenerates and
  /// retries on the astronomically rare collision instead of asking the
  /// admin to intervene.
  String _generateUsername(String name) {
    final base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final trimmed = base.isEmpty
        ? 'collector'
        : base.substring(0, base.length.clamp(0, 14));
    final suffix = 1000 + Random().nextInt(9000);
    return '$trimmed$suffix';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_birthday == null) {
      setState(() => _error = 'Select a birthday.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _name.text.trim();
      String? username;
      for (var attempt = 0; attempt < 5; attempt++) {
        final candidate = normalizeUsername(_generateUsername(name));
        try {
          await YosRepository.instance.resetCollectorPassword(
            oldUid: widget.collector.uid,
            oldName: widget.collector.name,
            name: name,
            username: candidate,
            phone: _phone.text.trim(),
            birthday: _birthday!,
            password: _password.text,
          );
          username = candidate;
          break;
        } on FirebaseAuthException catch (e) {
          if (e.code != 'email-already-in-use') rethrow;
          // Collision on the random suffix — vanishingly unlikely, but
          // retry with a new one rather than surfacing it as a failure.
        }
      }
      if (username == null) {
        throw StateError('Could not find an available username.');
      }
      if (!mounted) return;
      Toast.success(context,
          '${widget.collector.name}\'s access was reset — new username: $username');
      Navigator.of(context).pop(username);
    } on FirebaseAuthException catch (e) {
      setState(() => _error = authErrorMessage(e.code));
    } catch (e) {
      setState(() => _error = 'Couldn\'t reset access: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: YosColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reset access for ${widget.collector.name}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 18)),
                const SizedBox(height: 6),
                const Text(
                    'Their old sign-in stops working once this is saved. '
                    'A new username is generated automatically — pick a '
                    'passcode and tell them both directly, that\'s what '
                    'they\'ll use to sign in (and to link Face ID on any '
                    'new phone).',
                    style: TextStyle(color: YosColors.sub, fontSize: 13)),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? 'Enter their full name'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                  validator: (v) {
                    final digits = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                    return digits.length < 10 ? 'Enter a valid phone number' : null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _birthdayText,
                  readOnly: true,
                  onTap: _pickBirthday,
                  decoration: const InputDecoration(
                      labelText: 'Birthday', hintText: 'MM/DD/YYYY'),
                  validator: (_) =>
                      _birthday == null ? 'Select a birthday' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'New passcode',
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.length < 8) ? 'At least 8 characters' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _confirmPassword,
                  obscureText: _obscureConfirm,
                  decoration: InputDecoration(
                    labelText: 'Confirm passcode',
                    suffixIcon: IconButton(
                      icon: Icon(_obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: (v) =>
                      v != _password.text ? 'Passcodes don\'t match' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: YosColors.bad, fontSize: 13)),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed:
                            _busy ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Reset access'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
