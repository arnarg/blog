const COPY_RESET_DELAY_MS = 2000;

const createIcon = (content) => `
  <svg
    xmlns="http://www.w3.org/2000/svg"
    viewBox="0 0 24 24"
    class="copy-code-icon"
    fill="none"
    stroke="currentColor"
    stroke-width="2"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    focusable="false"
  >${content}</svg>`;

const CLIPBOARD_ICON = createIcon(`
  <rect width="8" height="4" x="8" y="2" rx="1" ry="1" />
  <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" />
`);
const CHECK_ICON = createIcon('<path d="m5 12 4 4L19 6" />');
const ERROR_ICON = createIcon('<path d="M18 6 6 18M6 6l12 12" />');

for (const block of document.querySelectorAll("article div.highlight")) {
  const code = block.querySelector("pre code");

  if (!code || typeof navigator.clipboard?.writeText !== "function") {
    continue;
  }

  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-code-button";
  button.setAttribute("aria-label", "Copy code block");
  button.title = "Copy code block";
  button.innerHTML = CLIPBOARD_ICON;

  const status = document.createElement("span");
  status.className = "copy-code-status";
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  status.setAttribute("aria-atomic", "true");

  let resetTimer;

  button.addEventListener("click", async () => {
    window.clearTimeout(resetTimer);
    button.disabled = true;

    try {
      await navigator.clipboard.writeText(code.textContent);
      button.innerHTML = CHECK_ICON;
      button.title = "Copied!";
      button.dataset.state = "success";
      status.textContent = "Code copied to clipboard.";
    } catch {
      button.innerHTML = ERROR_ICON;
      button.title = "Copy failed";
      button.dataset.state = "error";
      status.textContent = "Unable to copy code to clipboard.";
    } finally {
      button.disabled = false;
      resetTimer = window.setTimeout(() => {
        button.innerHTML = CLIPBOARD_ICON;
        button.title = "Copy code block";
        delete button.dataset.state;
        status.textContent = "";
      }, COPY_RESET_DELAY_MS);
    }
  });

  // Keep the button outside <pre> so horizontal code scrolling does not move it.
  block.prepend(button);
  block.append(status);
}
