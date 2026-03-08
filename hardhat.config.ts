import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";

const rpcUrl = process.env.RPC_URL || "http://127.0.0.1:8545";
const privateKey = process.env.DEPLOYER_PRIVATE_KEY;

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {},
    localhost: {
      url: rpcUrl,
      ...(privateKey && privateKey.startsWith("0x") ? { accounts: [privateKey] } : {}),
    },
  },
};

export default config;
