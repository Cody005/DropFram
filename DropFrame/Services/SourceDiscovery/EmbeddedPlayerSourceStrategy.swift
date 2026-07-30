import Foundation

/// Discovers media exposed by common JavaScript video players.
///
/// Keep site-shaped player configuration handling here so the shared resolver,
/// format validation, and downloader remain unchanged when another site needs
/// an additional discovery strategy.
enum EmbeddedPlayerSourceStrategy {
    static let captureScript = #"""
    const candidatesByURL = new Map();
    const metadataEndpoints = new Map();
    const visitedObjects = new WeakSet();
    const sourcePriority = {
        network: 0,
        dom: 1,
        player: 2,
        metadata: 3
    };
    const looksLikeMedia = value =>
        /\.(mp4|m4v|mov|webm|m3u8)(?:$|[?#])/i.test(value);
    const looksLikeMetadataEndpoint = value =>
        /\/video\/(?:get_)?media(?:[/?#]|$)/i.test(value)
        || /[?&](?:action|method)=(?:get_)?media(?:[&#]|$)/i.test(value);
    const looksAuxiliary = value =>
        /(?:^|[/_.?&=-])(?:advert|ads?|ima|preroll|promo|preview|storyboard|sprite|trailer|vast)(?:[/_.?&=-]|$)/i
            .test(value);
    const absoluteURL = value => {
        try {
            return new URL(value, document.baseURI).href;
        } catch {
            return value;
        }
    };
    const add = (url, label, source = "dom") => {
        if (!url || typeof url !== "string" || !looksLikeMedia(url)) return;
        const normalizedURL = absoluteURL(url);
        if (looksAuxiliary(normalizedURL)) return;

        const existing = candidatesByURL.get(normalizedURL);
        const nextPriority = sourcePriority[source] ?? 0;
        const existingPriority = sourcePriority[existing?.source] ?? -1;
        if (!existing || nextPriority > existingPriority) {
            candidatesByURL.set(normalizedURL, {
                url: normalizedURL,
                label: label || existing?.label || "",
                source
            });
        } else if (!existing.label && label) {
            existing.label = label;
        }
    };
    const addMetadataEndpoint = (url, label) => {
        if (!url || typeof url !== "string" || !looksLikeMetadataEndpoint(url)) return;
        const normalizedURL = absoluteURL(url);
        if (!metadataEndpoints.has(normalizedURL)) {
            metadataEndpoints.set(normalizedURL, label || "");
        }
    };

    document.querySelectorAll("video").forEach(video => {
        const label = video.getAttribute("data-quality") || video.videoHeight;
        add(video.currentSrc, label, "dom");
        add(video.src, label, "dom");
    });
    document.querySelectorAll("video source, source").forEach(source => {
        add(
            source.src || source.getAttribute("src"),
            source.getAttribute("label")
                || source.getAttribute("res")
                || source.getAttribute("data-quality")
                || source.getAttribute("title"),
            "dom"
        );
    });
    document.querySelectorAll(
        "[data-src], [data-video-url], [data-hls], [data-quality]"
    ).forEach(node => {
        const label = node.getAttribute("data-quality")
            || node.getAttribute("label")
            || node.getAttribute("title")
            || "";
        [
            node.getAttribute("data-src"),
            node.getAttribute("data-video-url"),
            node.getAttribute("data-hls"),
            node.getAttribute("href")
        ].forEach(url => {
            add(url, label, "dom");
            addMetadataEndpoint(url, label);
        });
    });

    let visitedNodes = 0;
    const qualityFrom = value => {
        if (typeof value === "number") return `${value}p`;
        if (typeof value !== "string") return "";
        const match = value.match(
            /(?:^|[^0-9])(144|240|360|480|540|576|720|1080|1440|2160|4320)p?(?:[^0-9]|$)/i
        );
        return match ? `${match[1]}p` : "";
    };
    const walkMediaConfig = (value, qualityHint, depth, source = "player") => {
        if (depth > 10 || visitedNodes > 16000 || value == null) return;
        visitedNodes += 1;
        if (typeof value === "string") {
            add(value, qualityHint, source);
            addMetadataEndpoint(value, qualityHint);
            return;
        }
        if (typeof value !== "object" || visitedObjects.has(value)) return;
        visitedObjects.add(value);

        const objectHint = qualityFrom(
            value.quality
                ?? value.qualityLabel
                ?? value.resolution
                ?? value.height
                ?? qualityHint
        ) || qualityHint;
        Object.entries(value).forEach(([key, child]) => {
            const nextHint = qualityFrom(key) || objectHint;
            walkMediaConfig(child, nextHint, depth + 1, source);
        });
    };

    const playerConfigKeys = Object.getOwnPropertyNames(window)
        .filter(key =>
            /^(?:flashvars(?:_|$)|initials$|xplayerSettings$|playerConfig$|videoModel$)/i.test(key)
            || /(?:player|video|media).*(?:config|definition|model|setting|source)/i.test(key)
        )
        .slice(0, 80);
    playerConfigKeys.forEach(key => {
        try {
            walkMediaConfig(window[key], "", 0, "player");
        } catch {
            // Some window properties throw when read. Other configurations
            // should still be inspected.
        }
    });

    performance.getEntriesByType("resource").forEach(entry => {
        add(entry.name, "", "network");
    });

    await Promise.all(
        Array.from(metadataEndpoints.entries()).slice(0, 8).map(
            async ([endpoint, label]) => {
                try {
                    const response = await fetch(endpoint, {
                        credentials: "include",
                        headers: {
                            Accept: "application/json,text/plain,*/*",
                            "X-Requested-With": "XMLHttpRequest"
                        }
                    });
                    if (!response.ok) return;
                    const contentType = response.headers.get("content-type") || "";
                    if (!contentType.includes("json") && !contentType.includes("text")) return;
                    const payload = await response.json();
                    walkMediaConfig(payload, label, 0, "metadata");
                } catch {
                    // The normal DOM and player configuration candidates are
                    // still usable when an optional metadata endpoint rejects.
                }
            }
        )
    );

    const candidates = Array.from(candidatesByURL.values());
    return {
        title: document.querySelector('meta[property="og:title"]')?.content
            || document.title
            || "",
        thumbnail: document.querySelector('meta[property="og:image"]')?.content
            || document.querySelector("video")?.poster
            || "",
        candidates
    };
    """#
}
