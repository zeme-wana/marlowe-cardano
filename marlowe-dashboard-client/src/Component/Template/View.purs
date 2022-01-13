module Component.Template.View (contractTemplateCard) where

import Prologue hiding (Either(..), div)
import Component.Contacts.State (adaToken, getAda)
import Component.Contacts.Types (AddressBook)
import Component.Hint.State (hint)
import Component.Icons (Icon(..)) as Icon
import Component.Icons (Icon, icon, icon_)
import Component.InputField.Lenses (_value)
import Component.InputField.Types (InputDisplayOptions)
import Component.InputField.Types (State) as InputField
import Component.InputField.View (renderInput)
import Component.Label.View as Label
import Component.LoadingSubmitButton.State (loadingSubmitButton)
import Component.Popper (Placement(..))
import Component.Template.Lenses
  ( _contractNicknameInput
  , _contractSetupStage
  , _contractTemplate
  , _roleWalletInputs
  , _slotContentInputs
  , _valueContentInputs
  )
import Component.Template.State (templateSetupIsValid)
import Component.Template.Types
  ( Action(..)
  , ContractSetupStage(..)
  , RoleError
  , SlotError
  , State
  , ValueError
  )
import Css as Css
import Data.Lens (view)
import Data.Map (Map)
import Data.Map as Map
import Data.Map.Ordered.OMap as OMap
import Data.Maybe (fromMaybe)
import Data.Tuple.Nested ((/\))
import Effect.Aff.Class (class MonadAff)
import Halogen.Css (classNames)
import Halogen.HTML
  ( ComponentHTML
  , HTML
  , PlainHTML
  , a
  , button
  , div
  , div_
  , h2
  , h3
  , h4
  , h4_
  , label
  , li
  , p
  , p_
  , span
  , span_
  , text
  , ul
  , ul_
  )
import Halogen.HTML.Events.Extra (onClick_)
import Halogen.HTML.Properties (enabled, for, id)
import Humanize (contractIcon, humanizeValue)
import MainFrame.Types (ChildSlots)
import Marlowe.Extended.Metadata
  ( ContractTemplate
  , MetaData
  , NumberFormat(..)
  , _contractName
  , _metaData
  , _slotParameterDescriptions
  , _valueParameterDescription
  , _valueParameterFormat
  , _valueParameterInfo
  )
import Marlowe.Market (contractTemplates)
import Marlowe.PAB (contractCreationFee)
import Marlowe.Semantics (Assets, TokenName)
import Marlowe.Template (orderContentUsingMetadata)
import Text.Markdown.TrimmedInline (markdownToHTML)
import Component.Tooltip.State (tooltip)
import Component.Tooltip.Types (ReferenceId(..))

contractTemplateCard
  :: forall m
   . MonadAff m
  => AddressBook
  -> Assets
  -> State
  -> ComponentHTML Action ChildSlots m
contractTemplateCard addressBook assets state =
  let
    contractSetupStage = view _contractSetupStage state

    contractTemplate = view _contractTemplate state
  in
    div
      [ classNames
          [ "h-full"
          , "grid"
          , "grid-rows-auto-auto-1fr"
          , "divide-y"
          , "divide-gray"
          ]
      ]
      [ h2
          [ classNames Css.cardHeader ]
          [ text "Contract templates" ]
      , contractTemplateBreadcrumb contractSetupStage contractTemplate
      , case contractSetupStage of
          Start -> contractSelection
          Overview -> contractOverview contractTemplate
          Setup -> contractSetup addressBook state
          Review -> contractReview assets state
      ]

------------------------------------------------------------
contractTemplateBreadcrumb
  :: forall p. ContractSetupStage -> ContractTemplate -> HTML p Action
contractTemplateBreadcrumb contractSetupStage contractTemplate =
  div
    [ classNames
        [ "overflow-x-auto"
        , "flex"
        , "align-baseline"
        , "px-4"
        , "gap-1"
        , "border-gray"
        , "border-b"
        , "text-xs"
        ]
    ]
    case contractSetupStage of
      Start -> [ activeItem "Templates" ]
      Overview ->
        [ previousItem "Templates" Start
        , arrow
        , activeItem contractTemplate.metaData.contractName
        ]
      Setup ->
        [ previousItem "Templates" Start
        , arrow
        , previousItem contractTemplate.metaData.contractName Overview
        , arrow
        , activeItem "Setup"
        ]
      Review ->
        [ previousItem "Templates" Start
        , arrow
        , previousItem contractTemplate.metaData.contractName Overview
        , arrow
        , previousItem "Setup" Setup
        , arrow
        , activeItem "Review and pay"
        ]
  where
  activeItem itemText =
    span
      [ classNames
          [ "whitespace-nowrap"
          , "py-2.5"
          , "border-black"
          , "border-b-2"
          , "font-semibold"
          ]
      ]
      [ text itemText ]

  previousItem itemText stage =
    a
      [ classNames
          [ "whitespace-nowrap"
          , "py-2.5"
          , "text-purple"
          , "border-transparent"
          , "border-b-2"
          , "hover:border-purple"
          , "font-semibold"
          ]
      , onClick_ $ SetContractSetupStage stage
      ]
      [ text itemText ]

  arrow = span [ classNames [ "mt-2" ] ] [ icon_ Icon.Next ]

contractSelection :: forall p. HTML p Action
contractSelection =
  div
    [ classNames [ "h-full", "overflow-y-auto" ] ]
    [ ul_ $ contractTemplateLink <$> contractTemplates
    ]
  where
  -- Cautionary tale: Initially I made these `divs` inside a `div`, but because they are very
  -- similar to the overview div for the corresponding contract template, I got a weird event
  -- propgation bug when clicking on the "back" button in the contract overview section. I'm not
  -- entirely clear on what was going on, but either Halogen's diff of the DOM or the browser
  -- itself ended up thinking that the "back" button in the contract overview was inside one of
  -- these `divs` (even though they are never rendered at the same time). Anyway, changing these
  -- to `li` items inside a `ul` (a perfectly reasonable semantic choice anyway) solves this
  -- problem.
  contractTemplateLink contractTemplate =
    li
      [ classNames
          [ "flex"
          , "gap-4"
          , "items-center"
          , "p-4"
          , "border-gray"
          , "border-b"
          , "cursor-pointer"
          ]
      , onClick_ $ SetTemplate contractTemplate
      ]
      [ contractIcon contractTemplate.metaData.contractType
      , div_
          [ h2
              [ classNames [ "font-semibold", "mb-2" ] ]
              [ text contractTemplate.metaData.contractName ]
          , p
              [ classNames [ "font-xs" ] ]
              $ markdownToHTML
                  contractTemplate.metaData.contractShortDescription
          ]
      , icon_ Icon.Next
      ]

contractOverview :: forall p. ContractTemplate -> HTML p Action
contractOverview contractTemplate =
  div
    [ classNames [ "h-full", "grid", "grid-rows-1fr-auto" ] ]
    [ div
        [ classNames [ "h-full", "overflow-y-auto", "p-4" ] ]
        [ h2
            [ classNames
                [ "flex"
                , "gap-2"
                , "items-center"
                , "text-lg"
                , "font-semibold"
                , "mb-2"
                ]
            ]
            [ contractIcon contractTemplate.metaData.contractType
            , text $ contractTemplate.metaData.contractName <> " overview"
            ]
        , p [ classNames [ "mb-4" ] ] $ markdownToHTML
            contractTemplate.metaData.contractShortDescription
        , p_ $ markdownToHTML contractTemplate.metaData.contractLongDescription
        ]
    , div
        [ classNames
            [ "flex", "items-baseline", "p-4", "border-gray", "border-t" ]
        ]
        [ a
            [ classNames [ "flex-1", "text-center" ]
            , onClick_ $ SetContractSetupStage Start
            ]
            [ text "Back" ]
        , button
            [ classNames $ Css.primaryButton <> [ "flex-1", "text-left" ] <>
                Css.withIcon Icon.ArrowRight
            , onClick_ $ SetContractSetupStage Setup
            ]
            [ text "Setup" ]
        ]
    ]

contractSetup
  :: forall m
   . MonadAff m
  => AddressBook
  -> State
  -> ComponentHTML Action ChildSlots m
contractSetup addressBook state =
  let
    metaData = view (_contractTemplate <<< _metaData) state

    contractName = view (_contractName) metaData

    contractNicknameInput = view _contractNicknameInput state

    roleWalletInputs = view _roleWalletInputs state

    slotContentInputs = view _slotContentInputs state

    valueContentInputs = view _valueContentInputs state

    contractNicknameInputDisplayOptions =
      { additionalCss: mempty
      , id_: "contractNickname"
      , placeholder: "E.g. My Marlowe contract"
      , readOnly: false
      , numberFormat: Nothing
      , valueOptions: mempty
      , after: Nothing
      , before:
          Just
            $ Label.render
                Label.defaultInput
                  { for = "contractNickname", text = contractName <> " title" }
      }
  in
    div
      [ classNames [ "h-full", "grid", "grid-rows-1fr-auto" ] ]
      [ div
          [ classNames [ "overflow-y-auto", "p-4" ] ]
          [ h2
              [ classNames [ "text-lg", "font-semibold", "mb-2" ] ]
              [ text $ contractName <> " setup" ]
          , ContractNicknameInputAction
              <$> renderInput
                contractNicknameInputDisplayOptions
                contractNicknameInput
          , roleInputs addressBook metaData roleWalletInputs
          , parameterInputs metaData slotContentInputs valueContentInputs
          ]
      , div
          [ classNames
              [ "flex", "items-baseline", "p-4", "border-gray", "border-t" ]
          ]
          [ a
              [ classNames [ "flex-1", "text-center" ]
              , onClick_ $ SetContractSetupStage Overview
              ]
              [ text "Back" ]
          , button
              [ classNames $ Css.primaryButton <> [ "flex-1", "text-left" ] <>
                  Css.withIcon Icon.ArrowRight
              , onClick_ $ SetContractSetupStage Review
              , enabled $ templateSetupIsValid state
              ]
              [ text "Review" ]
          ]
      ]

contractReview
  :: forall m
   . MonadAff m
  => Assets
  -> State
  -> ComponentHTML Action ChildSlots m
contractReview assets state =
  let
    hasSufficientFunds = getAda assets >= contractCreationFee

    metaData = view (_contractTemplate <<< _metaData) state

    slotContentInputs = view _slotContentInputs state

    valueContentInputs = view _valueContentInputs state
  in
    div
      [ classNames
          [ "flex"
          , "flex-col"
          , "p-4"
          , "gap-4"
          , "max-h-full"
          , "overflow-y-auto"
          ]
      ]
      [ div
          [ classNames [ "rounded", "shadow" ] ]
          [ h3
              [ classNames
                  [ "flex"
                  , "gap-1"
                  , "items-center"
                  , "leading-none"
                  , "text-sm"
                  , "font-semibold"
                  , "p-2"
                  , "mb-2"
                  , "border-gray"
                  , "border-b"
                  ]
              ]
              [ icon Icon.Terms [ "text-purple" ]
              , text "Terms"
              ]
          , div
              [ classNames [ "p-4" ] ]
              [ ul_ $ slotParameter metaData <$> Map.toUnfoldable
                  slotContentInputs
              , ul_ $ valueParameter metaData <$> Map.toUnfoldable
                  valueContentInputs
              ]
          ]
      , div
          [ classNames [ "rounded", "shadow" ] ]
          [ h3
              [ classNames
                  [ "p-4"
                  , "flex"
                  , "justify-between"
                  , "bg-lightgray"
                  , "font-semibold"
                  , "rounded-t"
                  ]
              ]
              [ span_ [ text "Demo wallet balance:" ]
              , span_ [ text $ humanizeValue adaToken $ getAda assets ]
              ]
          , div [ classNames [ "px-5", "pb-6", "md:pb-8" ] ]
              [ p
                  [ classNames [ "mt-4", "text-sm", "font-semibold" ] ]
                  [ text "Confirm payment of:" ]
              , p
                  [ classNames
                      [ "mb-4", "text-purple", "font-semibold", "text-2xl" ]
                  ]
                  [ text $ humanizeValue adaToken contractCreationFee ]
              , div
                  [ classNames [ "flex", "items-baseline" ] ]
                  [ a
                      [ classNames [ "flex-1", "text-center" ]
                      , onClick_ $ SetContractSetupStage Setup
                      ]
                      [ text "Back" ]
                  , loadingSubmitButton
                      { ref: "action-pay-and-start"
                      , caption: "Pay and start"
                      , styles: [ "flex-1" ]
                      , enabled: true
                      , handler: StartContract
                      }
                  ]
              , div
                  [ classNames [ "mt-4", "text-sm", "text-red" ] ]
                  if hasSufficientFunds then
                    []
                  else
                    [ text
                        "You have insufficient funds to initialise this contract."
                    ]
              ]
          ]
      ]

------------------------------------------------------------
slotParameter
  :: forall m
   . MonadAff m
  => MetaData
  -> Tuple String (InputField.State SlotError)
  -> ComponentHTML Action ChildSlots m
slotParameter metaData (key /\ slotContentInput) =
  let
    slotParameterDescriptions = view _slotParameterDescriptions metaData

    description = fromMaybe "no description available" $ OMap.lookup key
      slotParameterDescriptions

    value = view _value slotContentInput
  in
    parameter key description $ value <> " minutes"

valueParameter
  :: forall m
   . MonadAff m
  => MetaData
  -> Tuple String (InputField.State ValueError)
  -> ComponentHTML Action ChildSlots m
valueParameter metaData (key /\ valueContentInput) =
  let
    valueParameterFormats = map (view _valueParameterFormat)
      (view _valueParameterInfo metaData)

    numberFormat = fromMaybe DefaultFormat $ OMap.lookup key
      valueParameterFormats

    valueParameterDescriptions = map (view _valueParameterDescription)
      (view _valueParameterInfo metaData)

    description = fromMaybe "no description available" $ OMap.lookup key
      valueParameterDescriptions

    value = view _value valueContentInput

    formattedValue = case numberFormat of
      DefaultFormat -> value
      DecimalFormat _ prefix -> prefix <> " " <> value
      TimeFormat -> value <> " minutes"
  in
    parameter key description formattedValue

parameter
  :: forall m
   . MonadAff m
  => String
  -> String
  -> String
  -> ComponentHTML Action ChildSlots m
parameter label description value =
  li
    [ classNames [ "mb-2" ] ]
    [ h4_
        [ span
            [ classNames [ "text-sm", "text-darkgray", "font-semibold" ] ]
            [ text label ]
        , hint
            [ "ml-2" ]
            ("template-parameter-" <> label)
            Auto
            (markdownHintWithTitle label description)
        ]
    , p_ [ text value ]
    ]

-- We range over roleWalletInputs rather than all the parties in the contract. This excludes any `PK` parties.
-- At the moment, this is a good thing: we don't have a design for them, and we only use a `PK` party in one
-- special case, where it is read-only and would be confusing to show the user anyway. But if we ever need to
-- use `PK` inputs properly (and make them editable) we will have to rethink this.
roleInputs
  :: forall m
   . MonadAff m
  => AddressBook
  -> MetaData
  -> Map TokenName (InputField.State RoleError)
  -> ComponentHTML Action ChildSlots m
roleInputs addressBook metaData roleWalletInputs =
  templateInputsSection Icon.Roles "Roles"
    [ ul_ $ roleInput <$> Map.toUnfoldable roleWalletInputs ]
  where
  roleInput (tokenName /\ roleWalletInput) =
    let
      description = fromMaybe "no description available" $ Map.lookup tokenName
        metaData.roleDescriptions
    in
      templateInputItem tokenName description
        [ div
            [ classNames [ "relative" ] ]
            [ RoleWalletInputAction tokenName <$> renderInput
                (roleWalletInputDisplayOptions tokenName)
                roleWalletInput
            , button
                [ classNames [ "absolute", "top-4", "right-4" ]
                , onClick_ $ OpenCreateWalletCard tokenName
                , id $ "newContactForRole" <> tokenName
                ]
                [ icon Icon.NewContact [ "text-purple" ] ]
            , tooltip "Create a new contact for this role"
                (RefId $ "newContactForRole" <> tokenName)
                Left
            ]
        ]

  roleWalletInputDisplayOptions tokenName =
    { additionalCss: [ "pr-9" ]
    , id_: tokenName
    , placeholder: "Choose any nickname"
    , readOnly: false
    , numberFormat: Nothing
    , valueOptions: fst <$> Map.toUnfoldable addressBook
    , after: Nothing
    , before: Nothing
    }

parameterInputs
  :: forall m
   . MonadAff m
  => MetaData
  -> Map String (InputField.State SlotError)
  -> Map String (InputField.State ValueError)
  -> ComponentHTML Action ChildSlots m
parameterInputs metaData slotContentInputs valueContentInputs =
  templateInputsSection Icon.Terms "Terms"
    [ ul
        [ classNames [ "mb-4" ] ]
        $ valueInput
            <$> OMap.toUnfoldable
              ( orderContentUsingMetadata valueContentInputs
                  (OMap.keys metaData.valueParameterInfo)
              )
    , ul_
        $ slotInput
            <$> OMap.toUnfoldable
              ( orderContentUsingMetadata slotContentInputs
                  (OMap.keys metaData.slotParameterDescriptions)
              )
    ]
  where
  valueInput (key /\ inputField) =
    let
      valueParameterFormats = map (view _valueParameterFormat)
        (view _valueParameterInfo metaData)

      valueParameterDescriptions = map (view _valueParameterDescription)
        (view _valueParameterInfo metaData)

      numberFormat = fromMaybe DefaultFormat $ OMap.lookup key
        valueParameterFormats

      description = fromMaybe "no description available" $ OMap.lookup key
        valueParameterDescriptions
    in
      templateInputItem key description
        [ ValueContentInputAction key <$> renderInput
            (inputFieldOptions key false numberFormat)
            inputField
        ]

  slotInput (key /\ inputField) =
    let
      slotParameterDescriptions = view _slotParameterDescriptions metaData

      numberFormat = TimeFormat

      description = fromMaybe "no description available" $ OMap.lookup key
        slotParameterDescriptions
    in
      templateInputItem key description
        [ SlotContentInputAction key <$> renderInput
            (inputFieldOptions key true numberFormat)
            inputField
        ]

  inputFieldOptions
    :: forall w i. String -> Boolean -> NumberFormat -> InputDisplayOptions w i
  inputFieldOptions key readOnly numberFormat =
    { additionalCss: mempty
    , id_: key
    , placeholder: key
    , readOnly
    , numberFormat: Just numberFormat
    , valueOptions: mempty
    , after: Nothing
    , before: Nothing
    }

templateInputsSection
  :: forall p. Icon -> String -> Array (HTML p Action) -> HTML p Action
templateInputsSection icon' heading content =
  div
    [ classNames [ "mt-4" ] ]
    $
      [ h3
          [ classNames
              [ "flex"
              , "gap-1"
              , "items-center"
              , "leading-none"
              , "text-sm"
              , "font-semibold"
              , "pb-2"
              , "mb-2"
              , "border-gray"
              , "border-b"
              ]
          ]
          [ icon icon' [ "text-purple" ]
          , text heading
          ]
      ]
        <> content

templateInputItem
  :: forall m
   . MonadAff m
  => String
  -> String
  -> Array (ComponentHTML Action ChildSlots m)
  -> ComponentHTML Action ChildSlots m
templateInputItem id description content =
  li
    [ classNames [ "mb-2", "last:mb-0" ] ]
    $
      [ label
          [ classNames [ "block", "mb-2" ]
          , for id
          ]
          [ span
              [ classNames [ "text-sm", "font-semibold" ] ]
              [ text id ]
          , hint
              [ "ml-2" ]
              ("template-parameter-input-" <> id)
              Auto
              (markdownHintWithTitle id description)
          ]
      ]
        <> content

-- TODO: This function is also included in the Marlowe Playground code. We could/should move it
-- into a shared folder, but it's not obvious where. It could go in the Hint module, but then it
-- would introduce an unnecessary markdown dependency into the Plutus Playground. So some more
-- thought/restructuring is required.
markdownHintWithTitle :: String -> String -> PlainHTML
markdownHintWithTitle title markdown =
  div_
    $
      [ h4
          -- With min-w-max we define that the title should never break into
          -- a different line.
          [ classNames
              [ "no-margins"
              , "text-lg"
              , "font-semibold"
              , "flex"
              , "items-center"
              , "pb-2"
              , "min-w-max"
              ]
          ]
          [ icon Icon.HelpOutline [ "mr-1", "font-normal" ]
          , text title
          ]
      ]
        <> markdownToHTML markdown