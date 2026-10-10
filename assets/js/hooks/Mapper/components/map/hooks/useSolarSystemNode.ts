import { useMemo } from 'react';
import { MapSolarSystemType } from '../map.types';
import { NodeProps } from 'reactflow';
import { useMapRootSelector } from '@/hooks/Mapper/mapRootProvider';
import { useMapGetOption } from '@/hooks/Mapper/mapRootProvider/hooks/api';
import { useMapSelector, useMapState } from '@/hooks/Mapper/components/map/MapProvider';
import { useDoubleClick } from '@/hooks/Mapper/hooks/useDoubleClick';
import { Regions, REGIONS_MAP, SPACE_TO_CLASS } from '@/hooks/Mapper/constants';
import { isWormholeSpace } from '@/hooks/Mapper/components/map/helpers/isWormholeSpace';
import { getSystemClassStyles } from '@/hooks/Mapper/components/map/helpers';
import { EMPTY_CHARACTERS, sortWHClasses } from '@/hooks/Mapper/helpers';
import { CharacterTypeRaw, OutCommand, PingType, SystemSignature, WormholeDataRaw } from '@/hooks/Mapper/types';
import { useUnsplashedSignatures } from './useUnsplashedSignatures';
import { useSystemName } from './useSystemName';
import { LabelInfo, useLabelsInfo } from './useLabelsInfo';
import { getSystemStaticInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic';

const EMPTY_SIGNATURES: SystemSignature[] = [];

export interface SolarSystemNodeVars {
  id: string;
  selected: boolean;
  visible: boolean;
  isWormhole: boolean;
  classTitleColor: string | null;
  hasUserCharacters: boolean;
  showHandlers: boolean;
  regionClass: string | null;
  systemName: string;
  customName?: string | null;
  labelCustom: string | null;
  isShattered: boolean;
  tag?: string | null;
  status?: number;
  labelsInfo: LabelInfo[];
  dbClick: (event: React.MouseEvent<HTMLDivElement>) => void;
  sortedStatics: Array<string | number>;
  effectName: string | null;
  regionName: string | null;
  solarSystemId: string;
  solarSystemName: string | null;
  locked: boolean;
  hubs: string[];
  name: string | null;
  charactersInSystem: Array<CharacterTypeRaw>;
  userCharacters: string[];
  unsplashedLeft: Array<SystemSignature>;
  unsplashedRight: Array<SystemSignature>;
  wormholesData: Record<string, WormholeDataRaw>;
  isThickConnections: boolean;
  isRally: boolean;
  classTitle: string | null;
  temporaryName?: string | null;
  description: string | null;
  comments_count: number | null;
  // Whether THIS system is the one currently highlighted (e.g. by a search/center-on-system
  // action) - a boolean, not the raw highlighted system id, so a highlight landing on a DIFFERENT
  // system doesn't change this node's own selected value's identity. See `MapProvider.tsx`'s
  // `useMapSelector` doc: select scalars, not the shared field, to avoid an unrelated fan-out.
  systemHighlighted: boolean;
}

export const useSolarSystemNode = (props: NodeProps<MapSolarSystemType>): SolarSystemNodeVars => {
  const { id, data, selected } = props;
  const {
    id: solar_system_id,
    locked,
    name,
    tag,
    status,
    labels,
    temporary_name,
    linked_sig_eve_id: linkedSigEveId = '',
    description,
    comments_count,
  } = data;

  // Selector-based, not `useMapRootState()`: this hook runs once per node, so a plain
  // `useMapRootState()` read here would re-subscribe every node to every OTHER field on
  // `MapRootContextProps` (windowsSettings, comments, charactersCache, ...) via
  // `MapRootContext`'s native React propagation, on top of the system-specific slices below. See
  // docs/chewy/map-perf-findings.md.
  const isShowUnsplashedSignatures = useMapRootSelector(
    ['interfaceSettings'],
    d => d.interfaceSettings.isShowUnsplashedSignatures,
  );
  const systemSigs = useMapRootSelector(
    ['systemSignatures'],
    d => d.systemSignatures[solar_system_id] ?? EMPTY_SIGNATURES,
  );
  const isRally = useMapRootSelector(
    ['pings'],
    d => !!d.pings.find(x => x.solar_system_id === solar_system_id && x.type === PingType.Rally),
  );

  const systemStaticInfo = useMemo(() => {
    return getSystemStaticInfo(solar_system_id)!;
  }, [solar_system_id]);

  const {
    system_class,
    security,
    class_title,
    statics,
    effect_name,
    region_name,
    region_id,
    is_shattered,
    solar_system_name,
    constellation_name,
  } = systemStaticInfo;

  const isTempSystemNameEnabled = useMapGetOption('show_temp_system_name') === 'true';
  const isShowLinkedSigId = useMapGetOption('show_linked_signature_id') === 'true';
  const isShowLinkedSigIdTempName = useMapGetOption('show_linked_signature_id_temp_name') === 'true';

  const { outCommand } = useMapState();

  // Every one of these selects a SCALAR or a field that only changes when it's actually relevant
  // to THIS node, so a hover/drag/pan touching the shared map-wide state (`hoverNodeId`,
  // `visibleNodes`, `isConnecting`) only re-renders the node(s) whose own selected value flips -
  // not all N nodes on the map. See docs/chewy/map-perf-findings.md. `showHandlers` declares BOTH
  // `isConnecting` and `hoverNodeId` even though `isConnecting || hoverNodeId === id` short-
  // circuits past `hoverNodeId` on any render where `isConnecting` is already `true` - the
  // declared-keys list is what the selector COULD read, not just what it read on one render (the
  // dev-mode assertion in `useMapSelector` would otherwise never trip on a render where the
  // branch happens not to be taken, while this node would silently stop reacting to hover for the
  // rest of the session once `isConnecting` had been `true` even once).
  const visible = useMapSelector(['visibleNodes'], d => d.visibleNodes.has(id));
  const showHandlers = useMapSelector(['isConnecting', 'hoverNodeId'], d => d.isConnecting || d.hoverNodeId === id);
  const isThickConnections = useMapSelector(['isThickConnections'], d => d.isThickConnections);
  const showKSpaceBG = useMapSelector(['showKSpaceBG'], d => d.showKSpaceBG);
  const systemHighlighted = useMapSelector(['systemHighlighted'], d => d.systemHighlighted === solar_system_id);
  const wormholesData = useMapSelector(['wormholesData'], d => d.wormholesData);
  const userCharacters = useMapSelector(['userCharacters'], d => d.userCharacters);
  const hubs = useMapSelector(['hubs'], d => d.hubs);
  const charactersBucket = useMapSelector(
    ['charactersBySystem'],
    d => d.charactersBySystem.get(parseInt(solar_system_id, 10)) ?? EMPTY_CHARACTERS,
  );

  const charactersInSystem = useMemo(() => charactersBucket.filter(c => c.online), [charactersBucket]);

  const isWormhole = isWormholeSpace(system_class);

  const classTitleColor = useMemo(
    () => getSystemClassStyles({ systemClass: system_class, security }),
    [security, system_class],
  );

  const sortedStatics = useMemo(() => sortWHClasses(wormholesData, statics), [wormholesData, statics]);

  const linkedSigPrefix = useMemo(() => (linkedSigEveId ? linkedSigEveId.split('-')[0] : null), [linkedSigEveId]);

  const { labelsInfo, labelCustom } = useLabelsInfo({
    labels,
    linkedSigPrefix,
    isShowLinkedSigId,
  });

  const hasUserCharacters = useMemo(
    () => charactersInSystem.some(x => userCharacters.includes(x.eve_id)),
    [charactersInSystem, userCharacters],
  );

  const dbClick = useDoubleClick(() => {
    outCommand({
      type: OutCommand.openSettings,
      data: { system_id: solar_system_id },
    });
  });

  const space = showKSpaceBG ? REGIONS_MAP[region_id] : '';
  const regionClass = showKSpaceBG ? SPACE_TO_CLASS[space] || null : null;

  const { systemName, computedTemporaryName, customName } = useSystemName({
    isTempSystemNameEnabled,
    temporary_name,
    isShowLinkedSigIdTempName,
    linkedSigPrefix,
    name,
    systemStaticInfo,
  });

  const { unsplashedLeft, unsplashedRight } = useUnsplashedSignatures(systemSigs, isShowUnsplashedSignatures);

  const hubsAsStrings = useMemo(() => hubs.map(item => item.toString()), [hubs]);

  const regionName = useMemo(() => {
    if (region_id === Regions.Pochven) {
      return constellation_name;
    }

    return region_name;
  }, [constellation_name, region_id, region_name]);

  const nodeVars: SolarSystemNodeVars = {
    id,
    selected,
    visible,
    isWormhole,
    classTitleColor,
    hasUserCharacters,
    userCharacters,
    showHandlers,
    regionClass,
    systemName,
    customName,
    labelCustom,
    isShattered: is_shattered,
    tag,
    status,
    labelsInfo,
    dbClick,
    sortedStatics,
    effectName: effect_name,
    solarSystemId: solar_system_id.toString(),
    locked,
    hubs: hubsAsStrings,
    name,
    charactersInSystem,
    unsplashedLeft,
    unsplashedRight,
    wormholesData,
    isThickConnections,
    classTitle: class_title,
    temporaryName: computedTemporaryName,
    regionName,
    solarSystemName: solar_system_name,
    isRally,
    description,
    comments_count,
    systemHighlighted,
  };

  return nodeVars;
};
