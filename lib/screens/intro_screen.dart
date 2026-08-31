import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';
import '../widgets/glow_effects.dart';
import 'login_screen.dart';

/// Onboarding: barangay seal, cycling taglines, chunky pill CTA.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  static const _phrases = [
    'Log a vehicle in seconds',
    'Print receipts instantly',
    'Works even offline',
  ];
  int _i = 0;

  // Muted, looping, autoplaying — purely decorative motion behind the
  // content, not a video the collector is meant to watch/control.
  late final VideoPlayerController _video;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    _cycle();
    _video = VideoPlayerController.asset('assets/videos/intro_background.mp4')
      ..setLooping(true)
      ..setVolume(0)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _videoReady = true);
        _video.play();
      });
  }

  Future<void> _cycle() async {
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 2600));
      if (!mounted) return;
      setState(() => _i = (_i + 1) % _phrases.length);
    }
  }

  @override
  void dispose() {
    _video.dispose();
    super.dispose();
  }

  void _go() {
    Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, a, __) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.05), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: const LoginScreen(),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: YosColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_videoReady)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _video.value.size.width,
                height: _video.value.size.height,
                child: VideoPlayer(_video),
              ),
            ),
          // Moderate scrim: the video stays clearly visible and in
          // motion, but dimmed enough that the dark headline/tagline text
          // below reads easily over any part of it.
          Container(color: YosColors.bg.withOpacity(0.35)),
          TouchGlowOverlay(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const SizedBox(height: 16),
                const Spacer(),

                // Barangay seal — static, no ring/blob/sparkle chrome.
                PopIn(
                  delayMs: 100,
                  child: SizedBox(
                    height: 220,
                    width: double.infinity,
                    child: Center(
                      child: Image.asset(
                        'assets/icon/logo.png',
                        height: 190,
                        width: 190,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                const Spacer(),

                PopIn(
                  delayMs: 200,
                  child: Text(
                    'Deliver more,\neasily.',
                    style: text.displayLarge?.copyWith(fontSize: 44),
                  ),
                ),
                const SizedBox(height: 14),

                // Cycling tagline
                SizedBox(
                  height: 28,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween(
                                begin: const Offset(0, 0.6),
                                end: Offset.zero)
                            .animate(a),
                        child: child,
                      ),
                    ),
                    child: Text(
                      _phrases[_i],
                      key: ValueKey(_i),
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(color: Colors.black38, blurRadius: 8),
                          ]),
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                PopIn(
                  delayMs: 300,
                  child: SizedBox(
                    width: double.infinity,
                    child: BreathingGlowButton(
                      label: 'Login',
                      icon: Icons.face_retouching_natural,
                      onPressed: _go,
                    ),
                  ),
                ),
                const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
