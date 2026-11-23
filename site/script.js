// Small touches for the download page: click to copy the Homebrew
// commands, and a trail of dust behind the cursor over the landscape.

(() => {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Click (or Enter/Space) on the Homebrew box copies its commands and
  // shows a handwritten "copied" in the corner.
  const box = document.querySelector(".brew pre");
  const note = document.querySelector(".copied");
  if (box && note) {
    const copy = async () => {
      const text = box.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
        note.textContent = "copied";
      } catch {
        // No clipboard access: select the text so ⌘C works.
        const range = document.createRange();
        range.selectNodeContents(box);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        note.textContent = "press ⌘C";
      }
      note.classList.remove("show");
      void note.offsetWidth; // restart the animation
      note.classList.add("show");
    };
    box.addEventListener("click", copy);
    box.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        copy();
      }
    });
  }

  // The wax seal on the Download button shows the newest version from
  // the update feed. Until there is a release it keeps its monogram.
  const seal = document.querySelector(".seal-text");
  // Shrinks a version longer than the monogram until it fits inside the
  // seal's rim, whatever its length. Measured once the web font has loaded.
  const fitSeal = () =>
    document.fonts.ready.then(() => {
      seal.style.fontSize = "";
      const room = seal.parentElement.clientWidth - 14;
      const width = seal.offsetWidth; // Not scaled by the stamp animation.
      if (width > room) {
        const size = parseFloat(getComputedStyle(seal).fontSize);
        seal.style.fontSize = `${Math.floor((size * room) / width)}px`;
      }
    });
  if (seal) {
    fetch("appcast.xml")
      .then((response) => (response.ok ? response.text() : ""))
      .then((xml) => {
        const feed = new DOMParser().parseFromString(xml, "application/xml");
        const version = feed.getElementsByTagName("sparkle:shortVersionString")[0];
        if (version && version.textContent.trim()) {
          seal.textContent = `v${version.textContent.trim()}`;
          fitSeal();
        }
      })
      .catch(() => {});
  }

  // Dust kicked up behind the mouse, only over the landscape.
  const land = document.querySelector(".landscape");
  const canvas = document.querySelector(".dust");
  if (!land || !canvas || reducedMotion) return;

  const context = canvas.getContext("2d");
  // Sand and engraving-ink specks, so the dust shows on both the cream
  // ground and the blue sky.
  const colours = ["232, 214, 176", "244, 234, 213", "11, 57, 134"];
  const specks = [];
  let running = false;

  const resize = () => {
    const ratio = window.devicePixelRatio || 1;
    canvas.width = land.clientWidth * ratio;
    canvas.height = land.clientHeight * ratio;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
  };
  resize();
  window.addEventListener("resize", resize);

  land.addEventListener("pointermove", (event) => {
    if (event.pointerType !== "mouse") return;
    const bounds = land.getBoundingClientRect();
    const x = event.clientX - bounds.left;
    const y = event.clientY - bounds.top;
    for (let i = 0; i < 2; i += 1) {
      specks.push({
        x: x + (Math.random() - 0.5) * 6,
        y: y + (Math.random() - 0.5) * 6,
        dx: (Math.random() - 0.5) * 0.6,
        dy: -Math.random() * 0.5 - 0.1,
        size: Math.random() * 1.8 + 0.8,
        life: 1,
        fade: Math.random() * 0.015 + 0.012,
        colour: colours[Math.random() < 0.4 ? 2 : Math.floor(Math.random() * 2)],
      });
    }
    if (specks.length > 300) specks.splice(0, specks.length - 300);
    if (!running) {
      running = true;
      requestAnimationFrame(draw);
    }
  });

  function draw() {
    context.clearRect(0, 0, land.clientWidth, land.clientHeight);
    for (let i = specks.length - 1; i >= 0; i -= 1) {
      const speck = specks[i];
      speck.x += speck.dx;
      speck.y += speck.dy;
      speck.dy += 0.01; // settle back down
      speck.life -= speck.fade;
      if (speck.life <= 0) {
        specks.splice(i, 1);
        continue;
      }
      context.fillStyle = `rgba(${speck.colour}, ${speck.life * 0.8})`;
      context.beginPath();
      context.arc(speck.x, speck.y, speck.size, 0, Math.PI * 2);
      context.fill();
    }
    if (specks.length) {
      requestAnimationFrame(draw);
    } else {
      running = false;
    }
  }
})();
