const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();

const STEP = {
  START: "START",
  CATEGORY: "CATEGORY",
  BULK_INPUT: "BULK_INPUT",
  RESULT: "RESULT",
  HUMAN: "HUMAN",
};

const BOT_CONFIG_DOC = "bot_config/support_bot";

function normalize(value) {
  return String(value || "").trim().toLowerCase();
}

function asArray(value) {
  if (!Array.isArray(value)) return [];
  return value.map((v) => String(v || "").trim()).filter(Boolean);
}

function optionMap(options) {
  const map = new Map();
  options.forEach((opt) => map.set(normalize(opt), opt));
  return map;
}

function nowTs() {
  return admin.firestore.FieldValue.serverTimestamp();
}

function chatUserId(chatData, userMessageData) {
  const fromMessage = String(userMessageData.senderId || userMessageData.uid || "").trim();
  if (fromMessage) return fromMessage;
  return String(chatData.userId || chatData.uid || "").trim();
}

async function createBotMessage({ chatId, replyTo, text, options = [] }) {
  const ref = db.collection("chats").doc(chatId).collection("messages").doc();
  await ref.set({
    messageId: ref.id,
    chatId,
    sender: "bot",
    senderRole: "bot",
    senderId: "support-bot",
    text: String(text || "").trim(),
    message: String(text || "").trim(),
    options: asArray(options),
    replyTo: String(replyTo || "").trim(),
    seen: false,
    timestamp: admin.firestore.Timestamp.now(),
    serverTimestamp: nowTs(),
    createdAt: nowTs(),
  });
}

function defaultConfig() {
  return {
    enabled: true,
    steps: {
      START: {
        text: "Welcome to PureCuts Bulk Support 👋",
        options: ["Bulk Order Discount", "Product Availability", "Delivery Info"],
      },
      CATEGORY: {
        text: "Select product type:",
        options: ["Skincare", "Hair", "Equipment", "Mixed"],
      },
      BULK_INPUT: {
        text: "Please type your bulk order requirement (products, quantity, city, budget):",
        options: [],
      },
    },
  };
}

function normalizeConfig(config) {
  const base = config && typeof config === "object" ? config : {};
  const steps = base.steps && typeof base.steps === "object" ? { ...base.steps } : {};
  const legacyQuantityStep =
    steps.QUANTITY && typeof steps.QUANTITY === "object" ? steps.QUANTITY : null;
  const bulkInputStep =
    steps.BULK_INPUT && typeof steps.BULK_INPUT === "object" ? steps.BULK_INPUT : null;

  const fallbackBulkText =
    "Please type your bulk order requirement (products, quantity, city, budget):";

  steps.BULK_INPUT = {
    ...(bulkInputStep || {}),
    text:
      String(
        bulkInputStep?.text ||
          legacyQuantityStep?.text ||
          fallbackBulkText,
      ).trim() || fallbackBulkText,
    options: [],
  };

  if (steps.QUANTITY) {
    delete steps.QUANTITY;
  }

  return {
    ...defaultConfig(),
    ...base,
    steps: {
      ...defaultConfig().steps,
      ...steps,
      BULK_INPUT: {
        ...defaultConfig().steps.BULK_INPUT,
        ...steps.BULK_INPUT,
        options: [],
      },
    },
  };
}

function normalizeFlowStep(rawStep) {
  const step = String(rawStep || STEP.START).trim().toUpperCase();
  if (step === "QUANTITY") return STEP.BULK_INPUT;
  return step;
}

function isLegacyQuantityChoice(value) {
  const text = String(value || "").trim().toLowerCase();
  if (!text) return false;
  return /^(\d+\s*-\s*\d+|\d+\+)$/.test(text);
}

exports.onSupportMessageCreated = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const { chatId, messageId } = event.params;
    const messageData = snap.data() || {};

    // 1) Ignore if sender != user
    const sender = normalize(messageData.sender || messageData.senderRole);
    if (sender !== "user") return;

    // 9) Idempotency lock per user message
    const lockRef = db.doc(`chats/${chatId}/botLocks/${messageId}`);
    try {
      await lockRef.create({
        createdAt: nowTs(),
        status: "processing",
      });
    } catch (_) {
      logger.info("Duplicate bot trigger skipped", { chatId, messageId });
      return;
    }

    const chatRef = db.doc(`chats/${chatId}`);
    const configRef = db.doc(BOT_CONFIG_DOC);

    try {
      // 2) Fetch chat
      // 3) Fetch config
      const [chatSnap, configSnap] = await Promise.all([chatRef.get(), configRef.get()]);

      const chat = chatSnap.exists ? (chatSnap.data() || {}) : {};
      const flow = chat.supportFlow || {};
      const cfgRaw = configSnap.exists ? (configSnap.data() || {}) : defaultConfig();
      const cfg = normalizeConfig(cfgRaw);

      // 4) If disabled, return
      if (cfg.enabled === false) {
        await lockRef.set({ status: "skipped_disabled", finishedAt: nowTs() }, { merge: true });
        return;
      }

      const currentStep = normalizeFlowStep(flow.step);

      // 5) If HUMAN, return
      if (currentStep === STEP.HUMAN) {
        await lockRef.set({ status: "skipped_human", finishedAt: nowTs() }, { merge: true });
        return;
      }

      const startCfg = cfg.steps?.START || {};
      const categoryCfg = cfg.steps?.CATEGORY || {};
      const bulkInputCfg = cfg.steps?.BULK_INPUT || {};

      const startOptions = asArray(startCfg.options);
      const categoryOptions = asArray(categoryCfg.options);
      const resultOptions = ["Talk to Sales", "Place Order", "Start Over"];

      const startMap = optionMap(startOptions);
      const categoryMap = optionMap(categoryOptions);

      const inputRaw = String(messageData.text || messageData.message || "").trim();
      const input = normalize(inputRaw);

      const looksLikeStart = ["hi", "hii", "hello", "hey", "start", "start over", "restart"].includes(input);

      // 6) State machine
      if (currentStep === STEP.START) {
        await chatRef.set({
          supportFlow: {
            step: STEP.CATEGORY,
            selectedCategory: "",
            selectedQuantity: "",
            selectedRequirement: "",
            isCompleted: false,
          },
          updatedAt: nowTs(),
        }, { merge: true });

        await createBotMessage({
          chatId,
          replyTo: messageId,
          text: startCfg.text || "Welcome to PureCuts Bulk Support 👋",
          options: startOptions,
        });
      } else if (currentStep === STEP.CATEGORY) {
        if (looksLikeStart) {
          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: startCfg.text || "Welcome to PureCuts Bulk Support 👋",
            options: startOptions,
          });
          await lockRef.set({ status: "completed", finishedAt: nowTs() }, { merge: true });
          return;
        }

        const topLevelChoice = startMap.get(input);
        if (topLevelChoice) {
          if (normalize(topLevelChoice) === normalize("bulk order discount")) {
            await chatRef.set({
              supportFlow: {
                ...flow,
                step: STEP.BULK_INPUT,
                selectedCategory: "",
                selectedQuantity: "",
                selectedRequirement: "",
                isCompleted: false,
              },
              updatedAt: nowTs(),
            }, { merge: true });

            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: bulkInputCfg.text || "Please type your bulk order requirement (products, quantity, city, budget):",
              options: [],
            });
          } else if (normalize(topLevelChoice) === normalize("product availability")) {
            await chatRef.set({
              supportFlow: {
                ...flow,
                step: STEP.RESULT,
                selectedCategory: "Product Availability",
                selectedQuantity: "",
                selectedRequirement: "",
                isCompleted: false,
              },
              updatedAt: nowTs(),
            }, { merge: true });

            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: "Please share category or product names. We’ll confirm stock with priority handling.",
              options: ["Talk to Sales", "Start Over"],
            });
          } else if (normalize(topLevelChoice) === normalize("delivery info")) {
            await chatRef.set({
              supportFlow: {
                ...flow,
                step: STEP.RESULT,
                selectedCategory: "Delivery Info",
                selectedQuantity: "",
                selectedRequirement: "",
                isCompleted: false,
              },
              updatedAt: nowTs(),
            }, { merge: true });

            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: "Bulk orders usually ship within 2-5 business days based on location and stock.",
              options: ["Talk to Sales", "Start Over"],
            });
          }
        } else {
          const selectedCategory = categoryMap.get(input);
          if (!selectedCategory) {
            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: "Please choose one of the available options.",
              options: [...startOptions, ...categoryOptions],
            });
          } else {
            await chatRef.set({
              supportFlow: {
                ...flow,
                step: STEP.BULK_INPUT,
                selectedCategory,
                selectedQuantity: "",
                selectedRequirement: "",
                isCompleted: false,
              },
              updatedAt: nowTs(),
            }, { merge: true });

            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: bulkInputCfg.text || "Please type your bulk order requirement (products, quantity, city, budget):",
              options: [],
            });
          }
        }
      } else if (currentStep === STEP.BULK_INPUT) {
        if (looksLikeStart || input === normalize("start over") || input === normalize("restart")) {
          await chatRef.set({
            supportFlow: {
              step: STEP.START,
              selectedCategory: "",
              selectedQuantity: "",
              selectedRequirement: "",
              isCompleted: false,
            },
            updatedAt: nowTs(),
          }, { merge: true });

          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: startCfg.text || "Welcome to PureCuts Bulk Support 👋",
            options: startOptions,
          });
        } else if (input === normalize("talk to sales")) {
          await chatRef.set({
            supportFlow: {
              ...flow,
              step: STEP.HUMAN,
              isCompleted: true,
            },
            updatedAt: nowTs(),
          }, { merge: true });

          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: "Perfect. A sales specialist will connect with you shortly.",
            options: [],
          });
        } else {
          if (isLegacyQuantityChoice(inputRaw)) {
            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: "Please type your requirement details instead of selecting a quantity range.",
              options: [],
            });
            await lockRef.set({ status: "completed", finishedAt: nowTs() }, { merge: true });
            return;
          }

          const requirement = String(inputRaw || "").trim();
          if (!requirement) {
            await createBotMessage({
              chatId,
              replyTo: messageId,
              text: "Please type your bulk order requirement so our sales team can help.",
              options: [],
            });
            await lockRef.set({ status: "completed", finishedAt: nowTs() }, { merge: true });
            return;
          }

          const selectedCategory = String(flow.selectedCategory || "").trim();

          await chatRef.set({
            supportFlow: {
              ...flow,
              step: STEP.RESULT,
              selectedCategory,
              selectedQuantity: "",
              selectedRequirement: requirement,
              isCompleted: true,
            },
            updatedAt: nowTs(),
          }, { merge: true });

          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: "Thanks! We captured your bulk order request. Our team will get back to you shortly.",
            options: resultOptions,
          });

          await db.collection("bulkLeads").add({
            chatId,
            userId: chatUserId(chat, messageData),
            category: selectedCategory,
            requirement,
            timestamp: nowTs(),
          });
        }
      } else if (currentStep === STEP.RESULT) {
        if (input === normalize("talk to sales")) {
          // 7) Human takeover
          await chatRef.set({
            supportFlow: {
              ...flow,
              step: STEP.HUMAN,
              isCompleted: true,
            },
            updatedAt: nowTs(),
          }, { merge: true });

          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: "Perfect. A sales specialist will connect with you shortly.",
            options: [],
          });
        } else if (input === normalize("place order")) {
          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: "Great! Please continue with your order and share details if you need help.",
            options: ["Start Over"],
          });
        } else if (input === normalize("start over") || input === normalize("restart")) {
          await chatRef.set({
            supportFlow: {
              step: STEP.START,
              selectedCategory: "",
              selectedQuantity: "",
              selectedRequirement: "",
              isCompleted: false,
            },
            updatedAt: nowTs(),
          }, { merge: true });

          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: startCfg.text || "Welcome to PureCuts Bulk Support 👋",
            options: startOptions,
          });
        } else {
          await createBotMessage({
            chatId,
            replyTo: messageId,
            text: "Please choose one of the available actions.",
            options: resultOptions,
          });
        }
      }

      // keep chat message preview aligned
      await chatRef.set({
        lastMessage: String(inputRaw || "").trim(),
        lastMessageBy: String(messageData.senderId || "").trim() || "user",
        lastServerTimestamp: nowTs(),
        updatedAt: nowTs(),
      }, { merge: true });

      await lockRef.set({ status: "completed", finishedAt: nowTs() }, { merge: true });
    } catch (error) {
      logger.error("Support bot processing failed", {
        chatId,
        messageId,
        error: String(error?.message || error),
      });
      await lockRef.set(
        {
          status: "failed",
          error: String(error?.message || error),
          finishedAt: nowTs(),
        },
        { merge: true },
      );
      throw error;
    }
  },
);
