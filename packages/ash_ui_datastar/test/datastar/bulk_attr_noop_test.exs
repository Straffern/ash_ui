defmodule AshUi.Datastar.BulkAttrNoopTest do
  use ExUnit.Case, async: true

  alias AshUi.Datastar.FragmentRender

  test "replaying an identical iframe src patch preserves its contentDocument" do
    script =
      FragmentRender.bulk_attribute_patch_script([
        ["", "", ["pdf-frame"], [["src", "", "", ["/viewer.pdf?lease=stable"]]]]
      ])

    assert script =~ "if(n.getAttribute(a[0])!==v)n.setAttribute(a[0],v)"
    assert script =~ "if(n.hasAttribute(a[0]))n.removeAttribute(a[0])"
    node = System.find_executable("node") || flunk("node executable is required")

    probe = """
    const patch = #{Jason.encode!(script)};
    const attributes = new Map();
    const frame = {
      contentDocument: {generation: 0},
      srcWrites: 0,
      getAttribute(name) { return attributes.has(name) ? attributes.get(name) : null; },
      hasAttribute(name) { return attributes.has(name); },
      removeAttribute(name) { attributes.delete(name); },
      setAttribute(name, value) {
        attributes.set(name, value);
        if (name === "src") {
          this.srcWrites += 1;
          this.contentDocument = {generation: this.srcWrites};
        }
      }
    };
    const document = {
      createElement() {
        const textarea = {value: ""};
        Object.defineProperty(textarea, "innerHTML", {
          set(value) { textarea.value = value; }
        });
        return textarea;
      },
      getElementById(id) { return id === "pdf-frame" ? frame : null; }
    };
    globalThis.document = document;
    eval(patch);
    const writesAfterFirst = frame.srcWrites;
    const contentDocument = frame.contentDocument;
    for (let cycle = 0; cycle < 50; cycle += 1) eval(patch);
    process.stdout.write(JSON.stringify({
      writesAfterFirst,
      writesAfterCycles: frame.srcWrites,
      documentSurvived: contentDocument === frame.contentDocument
    }));
    """

    assert {output, 0} = System.cmd(node, ["-e", probe], stderr_to_stdout: true)

    assert Jason.decode!(output) == %{
             "writesAfterFirst" => 1,
             "writesAfterCycles" => 1,
             "documentSurvived" => true
           }
  end
end
