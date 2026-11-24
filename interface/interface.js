const resourceName = (typeof GetParentResourceName === "function") ? GetParentResourceName() : "evolution-spawnselector";

let allLocations = [];
let activeIndex = 1;
let cameraBusy = false;
let spawnBusy = false;
let cameraBusyTimer = null;

function parseNuiResponse(text) {
    if (!text) {
        return null;
    }

    try {
        return JSON.parse(text);
    } catch (_) {
        return text;
    }
}

function postNui(action, payload, onResponse) {
    try {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", `https://${resourceName}/${action}`, true);
        xhr.setRequestHeader("Content-Type", "application/json; charset=UTF-8");
        if (typeof onResponse === "function") {
            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4) {
                    onResponse(parseNuiResponse(xhr.responseText));
                }
            };
        }
        xhr.send(JSON.stringify(payload || {}));
    } catch (_) {}
}

function padNumber(value) {
    const number = Number(value) || 1;
    return number < 10 ? `0${number}` : `${number}`;
}

function cssUrl(path) {
    return `url('${path || "locations/valentine.jpg"}')`;
}

function getCurrentLocation() {
    return allLocations.find((location) => Number(location.index) === Number(activeIndex)) || allLocations[0] || {};
}

function setCameraBusy(state) {
    cameraBusy = state === true;
    document.body.classList.toggle("is-camera-busy", cameraBusy);

    if (cameraBusyTimer) {
        clearTimeout(cameraBusyTimer);
        cameraBusyTimer = null;
    }

    if (cameraBusy) {
        cameraBusyTimer = setTimeout(() => {
            setCameraBusy(false);
        }, 6500);
    }
}

function setSpawnBusy(state) {
    spawnBusy = state === true;
    document.body.classList.toggle("is-spawn-busy", spawnBusy);
}

function canUseSelector() {
    return !cameraBusy && !spawnBusy;
}

function requestCamera(action, payload) {
    if (!canUseSelector()) {
        return;
    }

    setCameraBusy(true);
    postNui(action, payload, (resp) => {
        if (resp && resp.busy) {
            setCameraBusy(false);
        }
    });
}

function requestSpawn(action) {
    if (!canUseSelector()) {
        return;
    }

    setSpawnBusy(true);
    postNui(action || "spawn", {}, (resp) => {
        if (resp && resp.busy) {
            setSpawnBusy(false);
        }
    });
}

function renderLocations(locations) {
    allLocations = Array.isArray(locations) ? locations : [];

    const grid = document.querySelector(".location-grid");
    const lastButton = document.querySelector(".last-button");
    if (!grid) {
        return;
    }

    const quickLast = allLocations.find((location) => location.last);
    if (lastButton) {
        if (quickLast) {
            lastButton.hidden = false;
            lastButton.dataset.index = quickLast.index;
        } else {
            lastButton.hidden = true;
            delete lastButton.dataset.index;
        }
    }

    const displayLocations = allLocations.filter((location) => !location.last).slice(0, 5);
    grid.innerHTML = displayLocations.map((location, position) => `
        <article class="location-card" data-index="${location.index}" style="--location-image: ${cssUrl(location.image)}">
            <div class="location-card-content">
                <span class="index">${padNumber(position + 1)}</span>
                <h3>${location.label || ""}</h3>
                <p>${location.region || "Fronteira"}</p>
            </div>
        </article>
    `).join("");

    grid.querySelectorAll(".location-card").forEach((card) => {
        card.addEventListener("click", () => {
            if (!canUseSelector()) {
                return;
            }

            const index = Number(card.dataset.index);
            activeIndex = index;
            updateActiveFromIndex(index);
            requestCamera("select", { index });
        });
    });
}

function updateActiveFromIndex(index) {
    activeIndex = Number(index) || 1;
    const location = getCurrentLocation();

    document.querySelectorAll(".location-card").forEach((card) => {
        card.classList.toggle("active", Number(card.dataset.index) === activeIndex);
    });

    const featuredName = document.querySelector(".featured-name");
    const featuredRegion = document.querySelector(".featured-region");
    const featuredCount = document.querySelector(".featured-count");

    if (featuredName) {
        featuredName.textContent = location.label || "";
    }

    if (featuredRegion) {
        featuredRegion.textContent = location.region || "Fronteira";
    }

    if (featuredCount) {
        const displayLocations = allLocations.filter((item) => !item.last);
        const visiblePosition = displayLocations.findIndex((item) => Number(item.index) === activeIndex) + 1;
        featuredCount.textContent = `${padNumber(Math.max(visiblePosition, 1))} / ${padNumber(Math.max(displayLocations.length, 1))}`;
    }
}

window.addEventListener("message", function(event) {
    const data = event.data || {};

    if (data.locations) {
        renderLocations(data.locations);
    }

    if (data.event === "show") {
        document.body.style.display = "block";
        setSpawnBusy(false);
        setCameraBusy(false);
        updateActiveFromIndex(data.active || data.index || 1);
        return;
    }

    if (data.event === "hide") {
        document.body.style.display = "none";
        setSpawnBusy(false);
        setCameraBusy(false);
        return;
    }

    if (data.event === "update") {
        updateActiveFromIndex(data.index || activeIndex);
    }

    if (data.event === "cameraBusy") {
        setCameraBusy(data.busy === true);
        if (data.index) {
            updateActiveFromIndex(data.index);
        }
    }
});

document.addEventListener("DOMContentLoaded", function() {
    document.querySelectorAll("[data-action]").forEach((el) => {
        el.addEventListener("click", () => {
            const actionType = el.getAttribute("data-action");
            if (actionType === "lastloc" && el.dataset.index) {
                if (!canUseSelector()) {
                    return;
                }

                activeIndex = Number(el.dataset.index);
                updateActiveFromIndex(activeIndex);
                requestSpawn("lastloc");
                return;
            }

            if (actionType === "forward" || actionType === "backward") {
                requestCamera(actionType);
                return;
            }

            requestSpawn(actionType);
        });
    });

    const spawnBtn = document.querySelector(".spawn");
    if (spawnBtn) {
        spawnBtn.addEventListener("click", () => {
            requestSpawn("spawn");
        });
    }

    document.addEventListener("keydown", (event) => {
        if (window.getComputedStyle(document.body).display === "none") {
            return;
        }

        if (event.key === "ArrowLeft" || event.key === "a" || event.key === "A") {
            requestCamera("backward");
        }

        if (event.key === "ArrowRight" || event.key === "d" || event.key === "D") {
            requestCamera("forward");
        }

        if (event.key === "Enter") {
            requestSpawn("spawn");
        }
    });

    postNui("ready");
});
