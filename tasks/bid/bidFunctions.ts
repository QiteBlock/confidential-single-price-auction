import { FhevmInstance } from "fhevmjs/node";

import { MockERC20, PrivateSinglePriceAuction } from "../../types";

export async function bidAuction(
  bidderNumber: number,
  signerNumber: number,
  priceS: string,
  quantityS: string,
  lockS: string,
  ethers: any,
  paymentToken: MockERC20,
  privateAuction: PrivateSinglePriceAuction,
  signers: any,
  fhevm: FhevmInstance,
) {
  await paymentToken
    .connect(signers[signerNumber])
    .approve(await privateAuction.getAddress(), ethers.parseEther(lockS));
  await privateAuction.connect(signers[signerNumber]).lockFunds(ethers.parseEther(lockS));
  const price = ethers.parseEther(priceS);
  const quantity = ethers.parseEther(quantityS);
  const input = fhevm.createEncryptedInput(await privateAuction.getAddress(), signers[signerNumber].address);
  input.add256(quantity);
  input.add256(price);
  const encryptedAmount = await input.encrypt();
  const tx = await privateAuction
    .connect(signers[signerNumber])
    ["placeEncryptedBid(bytes32,bytes32,bytes)"](
      encryptedAmount.handles[0],
      encryptedAmount.handles[1],
      encryptedAmount.inputProof,
    );
  const rcpt = await tx.wait();
  console.info("Place Encrypted Bid tx hash: ", rcpt!.hash);
}
