defmodule WandererApp.Scout.Status do
  @moduledoc """
  CHEWY PATCH: the six families the merged `status` column on
  `WandererApp.Api.ScoutStructureSighting` falls into, defined ONCE so
  every reader (resource read actions, the `/scout` LiveView, any future
  export) groups the same way. See `docs/chewy/scout-intel.md` for the
  full 16-row precedence table that produces the `status` value itself
  -- that derivation happens client-side, in eveknob's
  `obj_StructureWatch.iss`; this module only names the groups the
  already-derived value falls into.

  Each function returns a plain list of the exact PascalCase strings
  stored in the `status` column -- no boolean predicate, so a caller can
  `Enum.member?/2` it, hand it to `in` inside an `Ash.Query.filter`, or
  render it as a filter-chip label directly.
  """

  # Rows 3-7: deploying, not deployed. The cheapest-kill window -- no
  # fitting, no services online yet. `Unanchored` used to live here and
  # does not any more: see `unanchored_family/0`.
  @anchoring_family ~w(Anchoring AnchorVulnerable Deploying Fitting Onlining)

  # Row 2 (`structure_state == 1`, STATE_UNANCHORED). Its own family
  # since 1.103.4-chewy.54: a structure sitting in space unanchored is
  # the single highest-value finding this log produces -- no fitting, no
  # services, nothing to shoot back -- and the page alerts on it rather
  # than listing it. Folding it into the anchoring family buried it in a
  # table of half-built Astrahuses.
  @unanchored_family ~w(Unanchored)

  # Row 1. A structure being pulled out of the ground: a one-shot
  # opportunity with a hard deadline, kept separate from the anchoring
  # family even though it outranks it in the precedence table.
  @unanchoring_family ~w(Unanchoring)

  # Rows 9-10 (Upwell) + the orbital ShieldReinforced label. Hull vs
  # armor vs shield is kept distinct in storage; this is only the group.
  @reinforced_family ~w(ArmorReinforced HullReinforced ShieldReinforced)

  # Rows 11-12: a running timer, shootable right now.
  @vulnerable_family ~w(ArmorVulnerable HullVulnerable)

  # Row 8 and row 13: asset safety off, or simply unfuelled. The
  # highest-value findings short of an active timer.
  @dead_family ~w(Abandoned NoFuel)

  # Rows 14-15 plus the orbital steady labels: boring, still not
  # journalled by the eveknob writer (unchanged behaviour).
  @steady_family ~w(FullPower Anchored ShieldVulnerable FobInvulnerable)

  @doc "Anchoring, AnchorVulnerable, Deploying, Fitting, Onlining."
  @spec anchoring_family() :: [String.t()]
  def anchoring_family, do: @anchoring_family

  @doc "Unanchored — on its own, and alerted on."
  @spec unanchored_family() :: [String.t()]
  def unanchored_family, do: @unanchored_family

  @doc "Unanchoring."
  @spec unanchoring_family() :: [String.t()]
  def unanchoring_family, do: @unanchoring_family

  @doc "ArmorReinforced, HullReinforced, ShieldReinforced."
  @spec reinforced_family() :: [String.t()]
  def reinforced_family, do: @reinforced_family

  @doc "ArmorVulnerable, HullVulnerable."
  @spec vulnerable_family() :: [String.t()]
  def vulnerable_family, do: @vulnerable_family

  @doc "Abandoned, NoFuel."
  @spec dead_family() :: [String.t()]
  def dead_family, do: @dead_family

  @doc "FullPower, Anchored, ShieldVulnerable, FobInvulnerable."
  @spec steady_family() :: [String.t()]
  def steady_family, do: @steady_family
end
