// SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract GreenMoveToken is Ownable, ERC20 {
  using ECDSA for bytes32;

  address constant DEAD = 0x000000000000000000000000000000000000dEaD;

  uint256 private _totalSupply;
  mapping(address => uint256) private _balances;
  uint256 private _accumulatedReflection;
  mapping (address => uint256) private _reflectionDebts;
  address private _pair;

  uint256 public holders;
  mapping (address => uint256) public lastTransfer;
  uint256 public rewarded;
  uint256 public donated;
  uint256 public fee;
  address public charityWallet;
  address public marketingWallet;
  address public developmentWallet;
  address public signer;
  mapping (address => bool) public solvedCaptchas;
  bool public antiBotEnabled;
  bool public launched;
  mapping (uint256 => uint256) public nonces;
  mapping (uint256 => mapping (uint256 => bool)) public usedNonces;

  event FeeChanged(uint256 previousFee, uint256 newFee);
  event CharityWalletChanged(address indexed previousCharityWallet, address indexed newCharityWallet);
  event MarketingWalletChanged(address indexed previousMarketingWallet, address indexed newMarketingWallet);
  event DevelopmentWalletChanged(address indexed previousDevelopmentWallet, address indexed newDevelopmentWallet);
  event SignerChanged(address indexed previousSigner, address indexed newSigner);
  event CaptchaSolved(address indexed account);
  event AntiBotEnabledChanged(bool previousAntiBotEnabled, bool newAntiBotEnabled);
  event Launched();
  event ChainTransfer(uint256 srcChain, uint256 dstChain, uint256 nonce, address indexed sender, address indexed recipient, uint256 amount);

  constructor() ERC20("Green Move", "GM") {
    _totalSupply = 10 ** decimals() * 1000000000;
    _updateBalance(_msgSender(), _totalSupply, true);
    emit Transfer(address(0), _msgSender(), _totalSupply);

    if (block.chainid == 1) { // Ethereum
      _pair = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f).createPair(address(this), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // Uniswap V2 pair
    } else if (block.chainid == 56) { // Binance Smart Chain Mainnet
      _pair = IUniswapV2Factory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73).createPair(address(this), 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c); // PancakeSwap V2 pair
    } else if (block.chainid == 97) { // Binance Smart Chain Testnet
      _pair = IUniswapV2Factory(0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc).createPair(address(this), 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd); // PancakeSwap KiemTienOnline360 pair
    } else {
      revert("GreenMoveToken: invalid chain");
    }

    developmentWallet = _msgSender();
    emit DevelopmentWalletChanged(address(0), developmentWallet);
  }

  function _receivesReflection(address account) private view returns (bool) {
    return account != address(this) && account != DEAD && account != _pair;
  }

  function _reflectionDebt(address account) private view returns (uint256) {
    return _accumulatedReflection * _balances[account] / 10 ** decimals();
  }

  function _reflection(address account) private view returns (uint256) {
    return _receivesReflection(account) ? Math.min(_reflectionDebt(account) - _reflectionDebts[account], _balances[address(this)]) : 0;
  }

  function _updateBalance(address account, uint256 amount, bool add) private {
    uint256 balance = _balances[account];
    bool isHolder = balance != 0;
    uint256 reflection = _reflection(account);

    if (reflection != 0) {
      _balances[address(this)] -= reflection;
      balance += reflection;
      emit Transfer(address(this), account, reflection);
    }

    if (amount != 0) {
      if (add) {
        balance += amount;

        if (!isHolder) {
          holders++;
        }

        if (lastTransfer[account] == 0) {
          lastTransfer[account] = block.timestamp;
        }
      } else {
        balance -= amount;

        if (isHolder && balance == 0) {
          holders--;
        }

        lastTransfer[account] = block.timestamp;
      }
    }

    _balances[account] = balance;

    if (_receivesReflection(account)) {
      _reflectionDebts[account] = _reflectionDebt(account);
    }
  }

  function _transfer(address sender, address recipient, uint256 amount) internal override {
    require(sender != address(0), "GreenMoveToken: transfer from the zero address");
    require(recipient != address(0), "GreenMoveToken: transfer to the zero address");
    require(recipient != _pair || !antiBotEnabled || solvedCaptchas[sender], "GreenMoveToken: anti-bot captcha not solved");
    require(sender != _pair || launched, "GreenMoveToken: not launched yet");
    _updateBalance(sender, amount, false);

    if (_balances[_pair] != 0) { // no fee until initial liquidity was provided
      if (sender == _pair) { // buying
        uint256 feeModifier = 10 ** decimals() * amount / _balances[_pair];

        if (feeModifier > fee) {
          feeModifier = fee;
        }

        uint256 newFee = fee - feeModifier; // decrease fee based on buy amount

        if (newFee != fee) {
          emit FeeChanged(fee, newFee);
          fee = newFee;
        }
      } else if (recipient == _pair) { // selling
        uint256 _fee = amount * fee / 10 ** decimals(); // charge fee to increase liquidity ratio (Auto LP) and price
        uint256 newFee = Math.min(fee + 10 ** decimals() * amount / _balances[_pair], 10 ** decimals() / 4); // increase fee based on sell amount to max. 25%

        if (newFee != fee) {
          emit FeeChanged(fee, newFee);
          fee = newFee;
        }

        if (_fee != 0) {
          amount -= _fee;
          _updateBalance(recipient, amount, true);
          emit Transfer(sender, recipient, amount);
          emit Transfer(sender, address(this), _fee);
          uint256 reflection = _fee / 2; // distribute 50% of fee to holders (Auto Reflection)
          _updateBalance(address(this), reflection, true);
          uint256 burn = _fee / 5; // burn 20% of fee
          _updateBalance(DEAD, burn, true);
          emit Transfer(address(this), DEAD, burn);
          uint256 charity;
          uint256 marketing;

          if (charityWallet != address(0)) {
            charity = _fee * 15 / 100; // send 15% of fee to charity wallet
            _updateBalance(charityWallet, charity, true);
            emit Transfer(address(this), charityWallet, charity);
            donated += charity;
          }

          if (marketingWallet != address(0)) {
            marketing = _fee / 10; // send 10% of fee to marketing wallet
            _updateBalance(marketingWallet, marketing, true);
            emit Transfer(address(this), marketingWallet, marketing);
          }

          _fee -= reflection + burn + charity + marketing; // send remaining fee to development wallet
          _updateBalance(developmentWallet, _fee, true);
          emit Transfer(address(this), developmentWallet, _fee);
          _accumulatedReflection += reflection * 10 ** decimals() / (_totalSupply - _balances[address(this)] - _balances[DEAD] - _balances[_pair]);
          rewarded += reflection;
          return;
        }
      }
    }

    _updateBalance(recipient, amount, true);
    emit Transfer(sender, recipient, amount);
  }

  function totalSupply() public view override returns (uint256) {
    return _totalSupply;
  }

  function balanceOf(address account) public view override returns (uint256) {
    return _balances[account] + _reflection(account);
  }

  function setCharityWallet(address _charityWallet) external onlyOwner {
    emit CharityWalletChanged(charityWallet, _charityWallet);
    charityWallet = _charityWallet;
  }

  function setMarketingWallet(address _marketingWallet) external onlyOwner {
    emit MarketingWalletChanged(marketingWallet, _marketingWallet);
    marketingWallet = _marketingWallet;
  }

  function setDevelopmentWallet(address _developmentWallet) external onlyOwner {
    emit DevelopmentWalletChanged(developmentWallet, _developmentWallet);
    developmentWallet = _developmentWallet;
  }

  function setSigner(address _signer) external onlyOwner {
    emit SignerChanged(signer, _signer);
    signer = _signer;
  }

  function _verifySignature(bytes memory abiEncoded, bytes memory signature) private view {
    require(keccak256(abiEncoded).toEthSignedMessageHash().recover(signature) == signer, "GreenMoveToken: invalid signature");
  }

  function solveCaptcha(bytes memory signature) external {
    _verifySignature(abi.encode(block.chainid, address(this), _msgSender()), signature);
    solvedCaptchas[_msgSender()] = true;
    emit CaptchaSolved(_msgSender());
  }

  function setAntiBotEnabled(bool _antiBotEnabled) external onlyOwner {
    emit AntiBotEnabledChanged(antiBotEnabled, _antiBotEnabled);
    antiBotEnabled = _antiBotEnabled;
  }

  function launch() external onlyOwner {
    launched = true;
    emit Launched();
  }

  function sendToChain(uint256 dstChain, address recipient, uint256 amount) external {
    require(amount != 0, "GreenMoveToken: bridging 0");
    address sender = _msgSender();
    _updateBalance(sender, amount, false);
    emit Transfer(sender, address(0), amount);
    _totalSupply -= amount;
    emit ChainTransfer(block.chainid, dstChain, nonces[dstChain]++, sender, recipient, amount);
  }

  function receiveFromChain(uint256 srcChain, uint256 nonce, address sender, uint256 amount, bytes memory signature) external {
    address recipient = _msgSender();
    _verifySignature(abi.encode(address(this), srcChain, block.chainid, nonce, sender, recipient, amount), signature);
    require(!usedNonces[srcChain][nonce], "GreenMoveToken: nonce already used");
    usedNonces[srcChain][nonce] = true;
    _totalSupply += amount;
    _updateBalance(recipient, amount, true);
    emit Transfer(address(0), recipient, amount);
    emit ChainTransfer(srcChain, block.chainid, nonce, sender, recipient, amount);
  }
}
