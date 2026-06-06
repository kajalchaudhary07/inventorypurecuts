class FeatureFlags {
  const FeatureFlags._();

  /// Toggle lightweight debug-only query telemetry.
  static const bool enablePerfTelemetry = bool.fromEnvironment(
    'ENABLE_PERF_TELEMETRY',
    defaultValue: true,
  );

  /// Toggle debug-only image bandwidth telemetry (cache hit/miss + bytes).
  static const bool enableImageBandwidthTelemetry = bool.fromEnvironment(
    'ENABLE_IMAGE_BANDWIDTH_TELEMETRY',
    defaultValue: true,
  );

  /// Rollout toggle for incremental order-history pagination.
  static const bool enableOrdersPaging = bool.fromEnvironment(
    'ENABLE_ORDERS_PAGING',
    defaultValue: true,
  );

  /// Time window in which a placed order can be edited.
  static const int orderEditWindowHours = int.fromEnvironment(
    'ORDER_EDIT_WINDOW_HOURS',
    defaultValue: 12,
  );

  /// Hard caps to prevent accidental high-cost reads.
  static const int maxProductPageSize = int.fromEnvironment(
    'MAX_PRODUCT_PAGE_SIZE',
    defaultValue: 200,
  );

  static const int defaultOrdersPageSize = int.fromEnvironment(
    'DEFAULT_ORDERS_PAGE_SIZE',
    defaultValue: 20,
  );

  static const int maxOrdersPageSize = int.fromEnvironment(
    'MAX_ORDERS_PAGE_SIZE',
    defaultValue: 50,
  );

  static const int maxOrdersFetch = int.fromEnvironment(
    'MAX_ORDERS_FETCH',
    defaultValue: 200,
  );

  /// Splash hardening flags (phase 1)
  static const bool enableSplashWatchdog = bool.fromEnvironment(
    'ENABLE_SPLASH_WATCHDOG',
    defaultValue: true,
  );

  static const int splashMinDurationMs = int.fromEnvironment(
    'SPLASH_MIN_DURATION_MS',
    defaultValue: 1700,
  );

  static const int splashWatchdogTimeoutMs = int.fromEnvironment(
    'SPLASH_WATCHDOG_TIMEOUT_MS',
    defaultValue: 7000,
  );

  static const int splashUserDocTimeoutMs = int.fromEnvironment(
    'SPLASH_USER_DOC_TIMEOUT_MS',
    defaultValue: 3500,
  );

  /// Home startup loading optimizations (phase 2)
  static const bool enableHomeStartupLite = bool.fromEnvironment(
    'ENABLE_HOME_STARTUP_LITE',
    defaultValue: true,
  );

  static const int homeStartupProductPool = int.fromEnvironment(
    'HOME_STARTUP_PRODUCT_POOL',
    defaultValue: 24,
  );

  static const bool enableDeferredHomeTaxonomy = bool.fromEnvironment(
    'ENABLE_DEFERRED_HOME_TAXONOMY',
    defaultValue: true,
  );

  static const bool enableHomeStartupCache = bool.fromEnvironment(
    'ENABLE_HOME_STARTUP_CACHE',
    defaultValue: true,
  );

  static const int homeProductsPageTimeoutMs = int.fromEnvironment(
    'HOME_PRODUCTS_PAGE_TIMEOUT_MS',
    defaultValue: 5500,
  );

  static const int homeBannersTimeoutMs = int.fromEnvironment(
    'HOME_BANNERS_TIMEOUT_MS',
    defaultValue: 4500,
  );

  static const int homeTaxonomyTimeoutMs = int.fromEnvironment(
    'HOME_TAXONOMY_TIMEOUT_MS',
    defaultValue: 5000,
  );

  /// PayU non-secret runtime config (keep SALT on backend only).
  static const String payuMerchantKey = String.fromEnvironment(
    'PAYU_MERCHANT_KEY',
    defaultValue: 'TEST_MERCHANT_KEY',
  );

  static const String payuEnvironment = String.fromEnvironment(
    'PAYU_ENVIRONMENT',
    defaultValue: '0',
  );

  static const String payuBackendBaseUrl = String.fromEnvironment(
    'PAYU_BACKEND_BASE_URL',
    defaultValue:
        'https://asia-south1-purecuts-11a7c.cloudfunctions.net/paymentApi',
  );

  static const String payuAndroidSuccessUrl = String.fromEnvironment(
    'PAYU_ANDROID_SURL',
    defaultValue: 'https://payu.herokuapp.com/success',
  );

  static const String payuAndroidFailureUrl = String.fromEnvironment(
    'PAYU_ANDROID_FURL',
    defaultValue: 'https://payu.herokuapp.com/failure',
  );

  static const String payuIosSuccessUrl = String.fromEnvironment(
    'PAYU_IOS_SURL',
    defaultValue: 'https://payu.herokuapp.com/success',
  );

  static const String payuIosFailureUrl = String.fromEnvironment(
    'PAYU_IOS_FURL',
    defaultValue: 'https://payu.herokuapp.com/failure',
  );
}
