/// TEMPORARY testing switches. To remove the pricing test tool for good:
/// delete the whole lib/dev/ folder, then the one dashboard tile that
/// references [kEnablePricingTestTool] (dashboard_screen.dart).
library;

/// Shows the "Pricing Test" tile on the dashboard — a sandbox for trying
/// time-in → time-out pricing and printouts without saving anything.
const bool kEnablePricingTestTool = true;
