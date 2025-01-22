import { createEIP712, createInstance as createFhevmInstance, generateKeypair } from "fhevmjs";
import { FhevmInstance } from "fhevmjs/node";
import { Network } from "hardhat/types";

import { ACL_ADDRESS, GATEWAY_URL, KMSVERIFIER_ADDRESS } from "../../test/constants";

const kmsAdd = KMSVERIFIER_ADDRESS;
const aclAdd = ACL_ADDRESS;

export const createInstance = async (network: Network): Promise<FhevmInstance> => {
  if (network.name === "sepolia") {
    const instance = await createFhevmInstance({
      kmsContractAddress: kmsAdd,
      aclContractAddress: aclAdd,
      networkUrl: network.config.url,
      gatewayUrl: GATEWAY_URL,
    });
    return instance;
  }
};
