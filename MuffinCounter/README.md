# MuffinCounter

A simple Windower addon that tracks gallimaufry (muffins) collected during your Sortie runs. That's it. That's the addon.

## Features

- Displays your total muffins and muffins gained during the run.
- On-screen display for displaying muffins earned.
- Includes commands for reporting your progress after a run, either privately to yourself, or in party chat.

## Installation

1. Download the latest release from [here](https://github.com/Daleterrence/MuffinCounter/releases)
2. Unzip the .zip file and then copy the `MuffinCounter` folder to your `Windower/addons/` directory
3. Load the addon with `//lua load muffincounter`
4. Will auto-load if `lua load muffincounter` is placed in your init.txt file, but recommended to load and unload as needed for Sortie runs. 

## Commands

- `//mc report` - Display how many muffins you gained this session in chat
- `//mc party` - Send your muffin gain count to party chat
- `//mc reset` - Reload the addon (resets gained muffins counter)
