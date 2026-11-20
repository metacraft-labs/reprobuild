const char *featlib_compiled_features(void) {
#if defined(FEATLIB_ALPHA) && defined(FEATLIB_BETA)
  return "alpha+beta";
#elif defined(FEATLIB_ALPHA)
  return "alpha";
#elif defined(FEATLIB_BETA)
  return "beta";
#else
  return "none";
#endif
}
