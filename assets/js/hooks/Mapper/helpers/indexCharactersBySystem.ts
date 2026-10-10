import { CharacterTypeRaw } from '@/hooks/Mapper/types/character.ts';

export const EMPTY_CHARACTERS: CharacterTypeRaw[] = [];

/**
 * Buckets characters by their current solar_system_id. Built ONCE every time `characters` is
 * written (every call site that writes `MapData.characters` must also write the matching
 * `charactersBySystem`, kept in lockstep so a node can look its bucket up in O(1) instead of
 * `characters.filter(...)`-ing the WHOLE map's character list on every one of its own renders.
 */
export const indexCharactersBySystem = (characters: CharacterTypeRaw[]): Map<number, CharacterTypeRaw[]> => {
  const bySystem = new Map<number, CharacterTypeRaw[]>();

  characters.forEach(character => {
    const systemId = character.location?.solar_system_id;
    if (systemId == null) {
      return;
    }

    const bucket = bySystem.get(systemId);
    if (bucket) {
      bucket.push(character);
    } else {
      bySystem.set(systemId, [character]);
    }
  });

  return bySystem;
};
