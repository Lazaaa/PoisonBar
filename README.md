
# PoisonBar

Rogue poison bar for the **Emberveil** server (WoW 1.12.1 API, UE5 client).
Shows the poison on your weapons and puts a new one on with one click.

## What it shows

One row per weapon (main hand, off hand):

- weapon icon
- chosen poison icon, with how many you carry (small number in the corner)
- poison name, **time left** and **charges** (`x35`)

The name turns **red** below 3 minutes or 10 charges. When a poison wears off
you get a sound and an on-screen warning. Without an off-hand weapon only one
row is shown.

## Usage

| Action | Result |
|---|---|
| **Left-click** a row | puts the chosen poison on that weapon |
| **Right-click** a row | choose the poison for that weapon (remembered) |
| Drag the title bar | move the bar |

If a poison is already on the weapon, the "replace enchantment?" question is
confirmed automatically.

## Commands

| Command | |
|---|---|
| `/pb mh`, `/pb oh` | apply poison to main / off hand (for macros or keys) |
| `/pb lock` | lock / unlock the bar |
| `/pb reset` | move the bar back to the default place |
| `/pb show`, `/pb hide` | show / hide the bar |
| `/pb warn 5` | turn red below 5 minutes |
| `/pb sound` | warning sound on / off |

## Installation

Copy the `PoisonBar` folder into `Interface\AddOns\` and restart the client.
Settings are saved per character (`PoisonBarDB`).

## Notes for this client

- The poison name is the one PoisonBar put on itself. A poison applied by hand
  shows as "Poison"; its time and charges are still correct.
- The bar is moved by its own code, because `StartMoving()` on this client only
  moves the picture and the frame snaps back.
- No hidden tooltip is used: the client shows it on screen even when hidden.

---

**Magyarul röviden:** bal klikk a soron feltesz egy mérget, jobb klikk a soron
kiválasztod, melyik méreg menjen arra a kézre. Az `x35` a fegyveren maradt
töltetek száma, a kis szám az ikon sarkában pedig a táskádban lévő darabszám.
A felső sávnál fogva mozgatható, `/pb lock` rögzíti.
