import 'package:flutter/material.dart';

import '../data/station_catalog.dart';
import 'real_station_map.dart';

class HomeMapPreview extends StatelessWidget {
  const HomeMapPreview({super.key, required this.station});

  final Station station;

  static const assetName = 'assets/maps/tokyo_home_map.png';

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${station.name}周辺の固定地図プレビュー。範囲は約500 m',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            child: Image.asset(
              assetName,
              key: const ValueKey('home-map-preview-image'),
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.high,
            ),
          ),
          const Positioned(top: 12, right: 12, child: _PreviewChip('↑ N')),
          const Positioned(
            bottom: 38,
            left: 12,
            child: _PreviewChip('範囲 約500 m'),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 30,
            child: Material(
              color: Colors.white,
              child: InkWell(
                onTap: () => showMapAttribution(context),
                child: const Center(
                  child: SizedBox(
                    key: ValueKey('home-map-attribution'),
                    child: Center(
                      child: Text(
                        '© OpenMapTiles · © OpenStreetMap contributors',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 9, color: Color(0xff52645f)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xf2ffffff),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xff52645f),
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
