
document.addEventListener("DOMContentLoaded", function () {
  const app = document.getElementById("app");
  let state = {
    screen: 0,
    authToken: "",
    role: "",
    privateKey: "",
    bootstrapUrl: "",
    peerUrls: "",
    genesisFile: null,
    nodeName: "",
    ceremonyToken: "",
    newPassword: "",
    confirmPassword: "",
    errors: {}
  };

  function render() {
    app.innerHTML = "";
    if (state.screen === 0) renderIntroScreen();
    else if (state.screen === 1) renderConfigScreen();
    else if (state.screen === 2) renderFinishScreen();
  }

  function inputError(field) {
    return state.errors[field] ? `<p class="text-red-400 text-sm mt-1">${state.errors[field]}</p>` : "";
  }

  function renderIntroScreen() {
    const div = document.createElement("div");
    div.innerHTML = `
      <h1 class="text-2xl mb-4">Welcome to tpnode Setup</h1>

      <label class="block mb-2">Node Role</label>
      <select class="w-full p-2 text-black" id="role">
        <option value="">-- select role --</option>
        <option value="rejoin">Rejoin Existing Chain</option>
        <option value="tea">Start New Chain (Tea Ceremony)</option>
        <option value="replica">Join as Replica Node</option>
      </select>
      ${inputError("role")}

      <label class="block mt-4 mb-2">Auth Token (from tpnode logs)</label>
      <input type="text" class="w-full p-2 text-black" id="authToken" value="${state.authToken}">
      ${inputError("authToken")}

      <div class="flex justify-between mt-6">
        <div></div>
        <button class="bg-blue-500 text-white px-4 py-2 rounded" onclick="nextFromIntro()">Next</button>
      </div>
    `;
    app.appendChild(div);
  }

  window.nextFromIntro = () => {
    state.authToken = document.getElementById("authToken").value.trim();
    state.role = document.getElementById("role").value;
    state.errors = {};

    if (!state.authToken) state.errors.authToken = "Auth token is required";
    if (!state.role) state.errors.role = "Please select a role";

    if (Object.keys(state.errors).length > 0) {
      render();
      return;
    }

    state.screen = 1;
    render();
  };

  function renderConfigScreen() {
    const div = document.createElement("div");
    let html = `<h2 class="text-xl mb-4">Configuration: ${state.role}</h2>`;

    function inputField(id, placeholder, value, type = "text") {
      return `
        <input type="${type}" placeholder="${placeholder}" id="${id}" class="w-full p-2 text-black mt-2" value="${value || ""}">
        ${inputError(id)}
      `;
    }

    if (state.role === "rejoin") {
      html += inputField("privateKey", "Private Key (HEX)", state.privateKey);
      html += inputField("bootstrapUrl", "Bootstrap Node URL", state.bootstrapUrl);
    } else if (state.role === "tea") {
      html += `
        <input type="checkbox" id="backupConfirm"> <label for="backupConfirm">I have backed up my private key</label>
        ${inputError("backupConfirm")}
      `;
      html += inputField("nodeName", "Node Name", state.nodeName);
      html += inputField("ceremonyToken", "Ceremony Token", state.ceremonyToken);
    } else if (state.role === "replica") {
      html += `
<button class="bg-gray-500 text-white px-4 py-2 rounded" onclick="generatePrivateKey()">Generate Private Key</button>
<input type="text" id="privateKey" placeholder="Private Key (HEX)" class="w-full p-2 bg-gray-800 text-white mt-2" value="${state.privateKey}">
${inputError("privateKey")}
      `;
      html += inputField("nodeName", "Node Name", state.nodeName);
      html += inputField("peerUrls", "Peer Node URLs (comma-separated)", state.peerUrls);
    }

    html += `
      <div class="flex justify-between mt-6">
        <button class="bg-gray-500 text-white px-4 py-2 rounded" onclick="goBack()">Back</button>
        <button class="bg-blue-500 text-white px-4 py-2 rounded" onclick="submitConfig()">Next</button>
      </div>
    `;
    div.innerHTML = html;
    app.appendChild(div);
  }

  window.generatePrivateKey = () => {
    const key = [...Array(64)].map(() => Math.floor(Math.random() * 16).toString(16)).join("");
    state.privateKey = key;
    Toastify({ text: "Private key generated", duration: 3000, gravity: "top", position: "right" }).showToast();
    render();
  };

  window.goBack = () => {
    state.screen--;
    render();
  };

  window.submitConfig = async () => {
    state.errors = {};

    const collect = (id) => document.getElementById(id)?.value?.trim() || "";

    state.privateKey = collect("privateKey");
    state.bootstrapUrl = collect("bootstrapUrl");
    state.peerUrls = collect("peerUrls");
    state.nodeName = collect("nodeName");
    state.ceremonyToken = collect("ceremonyToken");

    if (state.role === "start-new") {
      state.genesisFile = document.getElementById("genesisFile").files[0];
    }

    const payload = {
      role: state.role,
      privateKey: state.privateKey,
      bootstrapUrl: state.bootstrapUrl,
      peerUrls: state.peerUrls,
      nodeName: state.nodeName,
      ceremonyToken: state.ceremonyToken
    };

    try {
      const res = await fetch("/preconf/set_role", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": state.authToken
        },
        body: JSON.stringify(payload)
      });

      if (!res.ok) {
        const data = await res.json();
        if (data.errors) state.errors = data.errors;
        else Toastify({ text: "Error saving role", duration: 3000, gravity: "top", position: "right", backgroundColor: "red" }).showToast();
        render();
        return;
      }

      if (state.role === "start-new" && state.genesisFile) {
        const formData = new FormData();
        formData.append("file", state.genesisFile);
        const uploadRes = await fetch("/preconf/genesis", {
          method: "POST",
          headers: { "Authorization": state.authToken },
          body: formData
        });

        if (!uploadRes.ok) {
          Toastify({ text: "Genesis upload failed", duration: 3000, gravity: "top", position: "right", backgroundColor: "red" }).showToast();
          return;
        }
      }

      state.screen = 2;
      render();
    } catch (e) {
      Toastify({ text: "Network error", duration: 3000, gravity: "top", position: "right", backgroundColor: "red" }).showToast();
    }
  };

  function renderFinishScreen() {
    const div = document.createElement("div");
    div.innerHTML = `
      <h2 class="text-xl mb-4">Finish Setup</h2>
      <p>Please back up your configuration.</p>

      <label class="block mt-4">Change password?</label>
      <input type="password" placeholder="New Password" class="w-full p-2 text-black" id="newPassword">
      ${inputError("newPassword")}
      <input type="password" placeholder="Confirm Password" class="w-full p-2 text-black mt-2" id="confirmPassword">
      ${inputError("confirmPassword")}

      <div class="flex justify-between mt-6">
        <button class="bg-gray-500 text-white px-4 py-2 rounded" onclick="goBack()">Back</button>
        <button class="bg-green-500 text-white px-4 py-2 rounded" onclick="submitPassword()">Finish</button>
      </div>
    `;
    app.appendChild(div);
  }

  window.submitPassword = async () => {
    state.newPassword = document.getElementById("newPassword").value;
    state.confirmPassword = document.getElementById("confirmPassword").value;
    state.errors = {};

    if (state.newPassword !== state.confirmPassword) {
      state.errors.confirmPassword = "Passwords do not match";
      render();
      return;
    }

    try {
      const res = await fetch("/preconf/set_pw", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": state.authToken
        },
        body: JSON.stringify({ password: state.newPassword })
      });

      if (!res.ok) {
        const data = await res.json();
        if (data.errors) state.errors = data.errors;
        else Toastify({ text: "Password error", duration: 3000, gravity: "top", position: "right", backgroundColor: "red" }).showToast();
        render();
        return;
      }

      Toastify({ text: "Setup Complete!", duration: 3000, gravity: "top", position: "right", backgroundColor: "green" }).showToast();
    } catch (e) {
      Toastify({ text: "Network error", duration: 3000, gravity: "top", position: "right", backgroundColor: "red" }).showToast();
    }
  };

  // Logging logic
  var logTimestamp = 0;
  var logsRunning = false;
  var logRetryDelay = 1000; // initial delay
  const logRetryMax = 600000; // 10 minutes max

  function startLogPolling() {
    if (logsRunning || !state.authToken) return;
    logsRunning = true;
    pollLogs();
  }

  async function pollLogs() {
    try {
      const res = await fetch(`/preconf/tea_progress/${logTimestamp}`, {
        headers: { "Authorization": state.authToken }
      });
      if (res.status === 403) {
        Toastify({ text: "Token expired or invalid. Returning to step 1.", duration: 4000, gravity: "top", position: "right", backgroundColor: "orange" }).showToast();
        state.authToken = "";
        state.screen = 0;
        logsRunning = false;
        render();
        return;
      }
      const data = await res.json();
      if (data.ok) {
        if (data.data) {
          data.data.forEach(line => appendLog(line));
          logRetryDelay = 1000; // reset delay on success
          logTimestamp = data.t;
        }
      }
    } catch (err) {
      logRetryDelay = Math.min(logRetryDelay * 2, logRetryMax);
      // Ignore error, keep polling with same timestamp
    } finally {
      if (logsRunning) {
        setTimeout(pollLogs, logRetryDelay);
      }
    }
  }

  function appendLog(message) {
    const logFrame = document.getElementById("logFrame");
    if (!logFrame) return;

    const line = document.createElement("div");

    if (typeof message === "object") {
      line.textContent = JSON.stringify(message, null, 2);
    } else {
      line.textContent = message;
    }

    logFrame.appendChild(line);
    logFrame.scrollTop = logFrame.scrollHeight;
  }

  // Watch for token and start logs
  const tokenWatcher = setInterval(() => {
    if (state.authToken && !logsRunning) {
      startLogPolling();
    }
  }, 500);


  render();
});
