ExUnit.start()
ExUnit.configure(exclude: [:bench])

# bridge_test reuses FragmentRenderTest.Page — compile fixtures in a
# deterministic order regardless of file selection/seed
Code.require_file("datastar/fragment_render_test.exs", __DIR__)
