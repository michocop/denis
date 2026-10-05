# Motion and polish — design

Goal: make the app feel as finished as the apps people trust with money. Not
more decoration -- answers: the app should respond to every touch, arrive
rather than appear, and mark the moments that matter.

## The lots

Each lot is designed, approved and built on its own.

| Lot | What | Status |
|---|---|---|
| 1 | **Opening + motion language**: the animated opening, the vibration vocabulary, cascades, loading placeholders | built (this document) |
| 2 | **Celebrations**: commission earned, invoice signed, deal won -- particles in the brand colours, a richer vibration, a discreet sound | to design |
| 3 | **Data visuals**: monthly earnings chart, conversion ring, illustrated empty states | to design |
| 4 | **Premium features**: Home Screen widget, three-screen onboarding | to design |

Some of lot 3 landed separately in 33a9cd5: the stage pill, progress bar and
initials on the cards, and the counting figures on Home.

## Decisions

**No sound at launch.** The app is opened several times a day, often in front
of a client. Sound is kept for lot 2, for the one moment worth it, and honours
the silent switch.

**The opening is "Impulsion", in SwiftUI.** Chosen over a drawn-in logo and a
three-sided assembly because its first frame *is* the iOS launch screen: the
same night, the mark at the same size and position (86.4 pt inside the 96 pt
`LaunchLogo`, measured off the PNG and checked to the pixel on a recording).
Lottie and video were rejected: a dependency or a blurry bitmap, for a mark
that is three triangles.

- iOS draws the launch image's colours as Display P3, so the brand's #3C8BFF
  shows deeper there (0,141,255 against 60,139,255). The opening starts on that
  P3 blue and turns to the brand's inside the pulse, where it cannot be seen.
- It plays while the session is restored, never after it: `LaunchGate` lets it
  leave once it has played *and* the next screen is known. If the network is
  slower, the mark breathes where a spinner used to turn.
- Cold launch only. Reduce Motion: no waves, no swell, a 0.3 s fade.
- Whatever announces itself on arrival waits for it to go
  (`EnvironmentValues.contentRevealed`): the Face ID prompt, the notification
  permission prompt, the cascades. Before this, both prompts appeared over the
  opening.

**Vibrations are a vocabulary, and rare** (`Feedback`): selection (tabs,
segments, a card opened), tap (primary buttons, on press), success (stage
validated, recommendation sent, document accepted, invoice signed, Face ID,
deal won), warning (closed as lost, deleted, erased, credit note), error,
pulse (the opening). Nothing on secondary buttons, scrolling or typing; never
two at the same instant -- a signature that follows an SMS code does not
vibrate again.

**Cascades are capped** (`Motion.staggerDelay`): eight steps of 45 ms, then the
rest arrive together.

**Deferred: zooming a card into its detail.** Built with iOS 18's zoom
transition, then removed: on the simulator the detail lingered as a ghost over
the card for most of a second on the way back. Worth retrying on a device.

## Verification

- `MotionTests`: the gate (slow and fast network), the cascade cap, and that
  only stages, acceptances and signatures that went through are counted.
- The opening recorded on the simulator and checked frame by frame: position,
  colour, the name holding still while the waves grow, the prompts after it.
