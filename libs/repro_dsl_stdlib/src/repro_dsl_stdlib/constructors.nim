## DSL-port M9.R.2b — Layer-1 high-level constructor aggregator.

import ./constructors/c_library
import ./constructors/c_executable
import ./constructors/nim_library
import ./constructors/nim_executable
import ./constructors/meson_package
import ./constructors/cmake_package
import ./constructors/autotools_package

export c_library
export c_executable
export nim_library
export nim_executable
export meson_package
export cmake_package
export autotools_package
