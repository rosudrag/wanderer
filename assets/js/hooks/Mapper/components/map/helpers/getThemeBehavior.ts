// CHEWY PATCH: import Dotlan node component for theme registry
import { SolarSystemNodeDefault, SolarSystemNodeDotlan, SolarSystemNodeTheme } from '../components/SolarSystemNode';
import type { NodeProps } from 'reactflow';
import type { ComponentType } from 'react';
import { MapSolarSystemType } from '../map.types';
import { ConnectionMode } from 'reactflow';

export type SolarSystemNodeComponent = ComponentType<NodeProps<MapSolarSystemType>>;

interface ThemeBehavior {
  isPanAndDrag: boolean;
  nodeComponent: SolarSystemNodeComponent;
  connectionMode: ConnectionMode;
}

const THEME_BEHAVIORS: {
  [key: string]: ThemeBehavior;
} = {
  default: {
    isPanAndDrag: false,
    nodeComponent: SolarSystemNodeDefault,
    connectionMode: ConnectionMode.Loose,
  },
  pathfinder: {
    isPanAndDrag: true,
    nodeComponent: SolarSystemNodeTheme,
    connectionMode: ConnectionMode.Loose,
  },
  // CHEWY PATCH: dotlan theme — straight-line edges + pill nodes, dark canvas retained
  dotlan: {
    isPanAndDrag: false,
    nodeComponent: SolarSystemNodeDotlan,
    connectionMode: ConnectionMode.Loose,
  },
};

export function getBehaviorForTheme(themeName: string) {
  return THEME_BEHAVIORS[themeName] ?? THEME_BEHAVIORS.default;
}
