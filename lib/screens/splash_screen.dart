import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'intro_screen.dart';

/// Full-screen cinematic video splash. Plays assets/splash.mp4 once, then
/// fades into the intro screen. Tap anywhere to skip. If the video fails
/// to load for any reason, we skip to the intro immediately — never
/// leaves the user staring at a black screen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset('assets/splash.mp4')
      ..setVolume(0.0) // muted so no audio surprise on launch
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();
      }).catchError((_) {
        // No video? Skip straight to the intro so we never block launch.
        _next();
      });

    _controller.addListener(_onVideoTick);

    // Safety timeout: if the video hasn't started/finished within 8s
    // for any reason, move on so the user is never stuck here.
    Future.delayed(const Duration(seconds: 8), _next);
  }

  void _onVideoTick() {
    final v = _controller.value;
    if (v.isInitialized &&
        v.position >= v.duration &&
        v.duration > Duration.zero) {
      _next();
    }
  }

  void _next() {
    if (_navigated || !mounted) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 700),
      pageBuilder: (_, a, __) =>
          FadeTransition(opacity: a, child: const IntroScreen()),
    ));
  }

  @override
  void dispose() {
    _controller.removeListener(_onVideoTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _next,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready)
              // Cover the whole screen (crop if needed) — like a movie intro.
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                ),
              )
            else
              const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                      color: Colors.white70, strokeWidth: 2.5),
                ),
              ),
            Positioned(
              bottom: 34,
              left: 0,
              right: 0,
              child: Center(
                child: Opacity(
                  opacity: _ready ? 0.6 : 0.0,
                  child: const Text(
                    'Tap to skip',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
