# Ethos Heli Training

Ethos Heli Training is a FrSky Ethos training-game project focused on real stick discipline for aerobatic maneuvers.

- Piroflip Chase
- TicToc Rhythm
- Piro Rate Lock
- Collective Balance

## Project Layout

- `src/ethos-heli-training/main.lua` - system tool entrypoint
- `src/ethos-heli-training/games/freestyle/game.lua` - free-flight sandbox (fly heli around screen)
- `src/ethos-heli-training/games/piroflip-chase/game.lua` - heli piroflip timing trainer
- `src/ethos-heli-training/games/tictoc-rhythm/game.lua` - heli tic-toc beat trainer
- `src/ethos-heli-training/games/piro-rate-lock/game.lua` - piro rate + cyclic stability trainer
- `src/ethos-heli-training/games/collective-balance/game.lua` - flipping-heli collective tracking trainer
- `.vscode` - deploy scripts/tasks/launch configuration
- `.github/workflows` - PR/snapshot/release ZIP automation
- `deploy.json` - deploy target config (`tgt_name = ethos-heli-training`)


## Runtime Path

Deploy copies:

- `src/ethos-heli-training/*` -> `/scripts/ethos-heli-training/*`

Entry point:

- `/scripts/ethos-heli-training/main.lua`

## VS Code Deploy Tasks

- `Deploy & Launch [SIM]`
- `Deploy Radio`
- `Deploy Radio [Fast]`
- `Deploy Radio + Serial Debug`
- `Deploy Radio + Serial Debug [Fast]`

Language setting key:

- `ethoshelitraining.deploy.language`

## Controls

- Menu: choose game tile to launch
- In game, short/long `Enter`: reset current run
- `Exit`: close tool

Stick mapping (default Ethos analog members):

- Piroflip Chase: yaw controls target spin rate, collective controls chase marker
- TicToc Rhythm: match alternating TIC/TOC beats with elevator + collective
- Piro Rate Lock: match commanded yaw rate while minimizing cyclic drift
- Collective Balance: match collective to a continuously flipping heli attitude while keeping cyclic stable

## Release tags

- Snapshot builds: `snapshot/<version>`
- Release builds: `release/<version>`

-----
Like what you see.  Consider donating..

[![Donate](https://raw.githubusercontent.com/robthomson/ethos-arcade/main/.github/gfx/paypal-donate-button.png)](https://www.paypal.com/donate/?hosted_button_id=SJVE2326X5R7A)